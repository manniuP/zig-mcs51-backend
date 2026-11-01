//! mcs2 后端接线层（M0/M1）。
//!
//! M1 覆盖的 AIR 子集：`.arg`（≤4 字节，SDCC 寄存器 ABI）、
//! `.add_wrap / .sub_wrap`（8 位回绕算术）、`.ret / .ret_safe`（void 或 u8）。
//! 其余 AIR 明确报「未实现」，避免把不完整的代码静默写进固件。
//!
//! 路径合一：AIR → `mcs2/mir.Op` 序列 → `mcs2/mcs51.zig` 条目流
//! （lower → 窥孔 → render）→ `Mir.text`。selftest 通道与编译器通道
//! 共用同一发射管线，窥孔在编译器链路上同样生效。

const std = @import("std");
const link = @import("../link.zig");
const codegen = @import("../codegen.zig");
const Zcu = @import("../Zcu.zig");
const InternPool = @import("../InternPool.zig");
const Air = @import("../Air.zig");
const Type = @import("../Type.zig");
const Value = @import("../Value.zig");
const mcsmir = @import("mcs2/mir.zig");
const mcs51 = @import("mcs2/mcs51.zig");

pub const Mir = struct {
    text: std.ArrayListUnmanaged(u8) = .empty,

    pub fn deinit(mir: *Mir, gpa: std.mem.Allocator) void {
        mir.text.deinit(gpa);
    }

    pub fn emit(
        mir: Mir,
        lf: *link.File,
        pt: Zcu.PerThread,
        func_index: InternPool.Index,
        atom_id: link.File.AtomId,
        w: *std.Io.Writer,
        debug_output: link.File.DebugInfoOutput,
    ) (codegen.Error || std.Io.Writer.Error)!void {
        _ = lf;
        _ = pt;
        _ = func_index;
        _ = atom_id;
        _ = debug_output;
        try w.writeAll(mir.text.items);
    }
};

/// mcs2 当前不做 AIR legalize；复杂 AIR 由 generate 明确拒绝。
pub fn legalizeFeatures(_: *const std.Target) ?*const Air.Legalize.Features {
    return null;
}

/// Zig 会**并行**为不同函数做代码生成，而 vreg/标签/临时标签都是会话级计数器——
/// 必须串行化，否则两个函数会拿到同一个 base（实测：not8 与 xnor8 都拿到 0，
/// 结果 DSEG 槽重名、汇编器报 multiple definitions）。
var codegen_lock = std.atomic.Value(bool).init(false);

fn lockCodegen() void {
    while (codegen_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn unlockCodegen() void {
    codegen_lock.store(false, .release);
}

/// 单次编译会话内的全局 vreg 基线：同模块多函数的 DSEG 槽不撞名。
/// M1 简单累加（255 上限）；正式方案是 OVR 段覆盖或活跃期回收。
var session_vreg_base: u8 = 0;
var session_temp_base: u32 = 0x8000_0000;
/// 跨函数的标签域步长：每个函数预留 air 长度 ×2 的编号。
var session_label_base: u32 = 0;

/// 诊断开关（默认 false）：ISR 跳过 push/pop 保存恢复——仅定位 ucsim 中断行为时临时置 true。
/// 真机必须保存现场（主代码用 A/DPTR 时，ISR 不保存会踩坏返回值）。
var no_isr_save: bool = false;

/// 一个 8 位值的位置（M1：全部经 direct 寻址可达）。
const Loc = mcsmir.Byte;

/// 指针值：固定地址（`@ptrFromInt` 常量）、符号基址（全局/静态变量），
/// 各自再带「+ 运行期下标 × scale」。
const PtrRef = union(enum) {
    fixed: u64,
    /// scale = 元素字节数：地址 = base + idx*scale（2 = u16/函数指针，4 = u32）
    elem: struct { base: u64, idx: Loc, scale: u8 = 1 },
    /// 符号基址 + 常量偏移：地址 = _sym + off（全局变量的定长访问）
    sym_off: struct { sym: []const u8, off: u64 = 0 },
    /// 符号基址 + 运行期下标：地址 = _sym + off + idx*scale（`table[i]`，全局数组）
    elem_sym: struct { sym: []const u8, off: u64 = 0, idx: Loc, scale: u8 = 1 },
    /// `const` 表的定长访问：地址 = _sym + off，**在代码段**（`movc a,@a+dptr`）
    code_sym: struct { sym: []const u8, off: u64 = 0 },
    /// `const` 表 + 运行期下标（同上，代码段）
    code_elem_sym: struct { sym: []const u8, off: u64 = 0, idx: Loc, scale: u8 = 1 },
};

/// 带返回值块的结果槽：`inst` 是块指令，`base/width` 是 DSEG 槽。
const BlockSlot = struct { inst: Air.Inst.Index, base: u8, width: u8 };

/// M1 的线性降级器。不做活跃分析：`.arg` 原地用 ABI 寄存器（零序言），
/// 双目结果默认落新 vreg，唯一的单消费者优化是「ret 前看一眼」——
/// 结果直接写 DPL，省一次 vreg 往返（`add8` 预算内的关键一招）。
const Lower = struct {
    zcu: *Zcu,
    gpa: std.mem.Allocator,
    air: *const Air,
    nav: InternPool.Nav.Index,
    sym_name: []const u8, // mangled："_add_add"
    short_name: []const u8, // 导出名："add"（PARM 命名基准，SDCC 同款）
    ops: std.ArrayListUnmanaged(mcsmir.Op) = .empty,
    nregs: u8 = 0,
    arg_cursor: usize = 0,
    vals: []?Loc = &.{},
    ptr_vals: []?PtrRef = &.{},
    parms: std.ArrayListUnmanaged([]const u8) = .empty,
    /// 全局变量符号名池（`_sym`）：同一符号只分配一次，结束时统一释放。
    sym_pool: std.ArrayListUnmanaged([]const u8) = .empty,
    is_isr: bool = false,
    /// 多字节值（u16/u32）：低字节 = 首槽 vreg 号，高字节 = 字节数。
    wide: []?u16 = &.{},
    /// 多字节块的占用位图：这些 vreg 必须保持**连续直址**，
    /// 不能被寄存器分配切成 rN（否则块的第 k 字节就不是 base+k 了）。
    wide_blk: [256]bool = @splat(false),
    /// 溢出参数区的字节游标：第 2 个参数起，从 `_名_PARM_2` 开始连续编号。
    spill_off: usize = 2,
    /// 返回宽度：1 = u8（DPL）；2 = u16（DPL/DPH）。
    ret_wide: u8 = 1,
    ret_byte: ?u8, // u8 返回的 ABI 地址；void 时为 null
    saw_ret: bool = false,
    /// 本函数的标签基址（跨函数不复用，避免汇编符号重名）。
    label_base: u32 = 0,
    /// comptime 数组常量池：`const tbl = .{…}` 的 `tbl[i]`（运行期下标）在 AIR 里是
    /// `array_elem_val`，操作数是**聚合值**而不是符号 → 这里给它造一个代码段符号，
    /// 把字节原样发出去（每个函数各发一份；跨函数去重要跨函数状态，暂不做）。
    const_lines: std.ArrayListUnmanaged(u8) = .empty,
    const_seen: [16]?struct { idx: InternPool.Index, sym: []const u8 } = @splat(null),
    const_n: usize = 0,
    /// 带返回值的块（`if`/`switch` 表达式）：块结果槽 = **内存 phi**。
    /// 每条跳向该块的 `br` 把值写进槽，块尾标签之后读槽当结果。
    block_slots: std.ArrayListUnmanaged(BlockSlot) = .empty,
    /// 槽位池：`slot_used[v]` = 该槽当前被占用。**只在函数内部复用「临时操作数槽」**
    /// （`wideOperand` 为了把操作数摆成连续槽而拷的那几份）——它们在本条 AIR 指令内
    /// 就死了，复用绝对不会错。指令结果的槽仍然一人一个（真正的活跃期分析留 M2.14 后续）。
    slot_used: [256]bool = @splat(false),
    /// 本条指令里分配的可回收槽段（flushTemps 时归还）
    temp_runs: [24]struct { base: u8, n: u8 } = @splat(.{ .base = 0, .n = 0 }),
    temp_n: u8 = 0,
    /// arg2 是否落在 B 寄存器（0xF0）。MUL/DIV 会破坏 B，用到时要保存/恢复。
    b_is_arg: bool = false,
    /// 本模块是否用到 dptr（取址/解引用）。用到时 arg0（DPL）必须先搬进 vreg：
    /// 0x82 同时是 DPTR 低字节，地址计算会把它踩掉。
    needs_dptr: bool = false,
    /// MCS2_DUMP_AIR 环境变量：打印 AIR 指令序列（诊断用）。
    dump_air: bool = false,

    /// 存储宽度（**不是**算术宽度）：≤8 位一律 1 字节容器（u1/u5 这类只能当值存放），
    /// 16/32 按宽度。算术闸门仍然是 requireIntWidth（只认 8/16/32），
    /// 所以「能存」不会变成「能静默错算」。
    fn storageBytes(self: *Lower, ty: Type, comptime what: []const u8) codegen.Error!u8 {
        if (ty.zigTypeTag(self.zcu) != .int) return 1;
        const bits = ty.bitSize(self.zcu);
        if (bits <= 8) return 1;
        if (bits == 16) return 2;
        if (bits == 32) return 4;
        return self.fail(what ++ "：只支持 ≤32 位整数，当前 {d} 位", .{bits});
    }

    /// 固定地址解引用：interned ptr（base=.int）→ 字节地址；非固定地址 → null。
    fn constPtrAddr(self: *Lower, ref: Air.Inst.Ref) ?u64 {
        const ip_index = ref.toInterned() orelse return null;
        const key = self.zcu.intern_pool.indexToKey(ip_index);
        const ptr = switch (key) {
            .ptr => |p| p,
            else => return null,
        };
        switch (ptr.base_addr) {
            .int => return ptr.byte_offset,
            else => return null,
        }
    }

    /// 符号名池：同一文本只分配一次，函数结束时统一释放（SafeAllocator 查泄漏）。
    fn internSym(self: *Lower, text: []const u8) ?[]const u8 {
        for (self.sym_pool.items) |s| if (std.mem.eql(u8, s, text)) return s;
        const dup = self.gpa.dupe(u8, text) catch return null;
        self.sym_pool.append(self.gpa, dup) catch {
            self.gpa.free(dup);
            return null;
        };
        return dup;
    }

    /// comptime 聚合值（`const tbl = .{…}`）→ 代码段符号：把字节原样发成 `.db` 块。
    /// 同一个值在**本函数内**只发一次（跨函数去重要跨函数状态，暂不做）。
    fn internConstAggregate(self: *Lower, idx: InternPool.Index, ty: Type) codegen.Error![]const u8 {
        var i: usize = 0;
        while (i < self.const_n) : (i += 1) {
            const e = self.const_seen[i] orelse continue;
            if (e.idx == idx) return e.sym;
        }
        const size: usize = @intCast(ty.abiSize(self.zcu));
        if (size == 0) return self.fail("零长度常量数组不能下标", .{});
        const buf = try self.gpa.alloc(u8, size);
        defer self.gpa.free(buf);
        const val = Value.fromInterned(idx);
        val.writeToMemory(self.zcu, buf) catch
            return self.fail("这个常量表的初值取不出来（可能含函数指针/重定位），不能放进代码段", .{});

        const sym = try std.fmt.allocPrint(self.gpa, "_mcs_k{s}_{d}", .{ self.short_name, self.const_n });
        self.sym_pool.append(self.gpa, sym) catch {
            self.gpa.free(sym);
            return error.OutOfMemory;
        };
        if (self.const_n < self.const_seen.len) {
            self.const_seen[self.const_n] = .{ .idx = idx, .sym = sym };
            self.const_n += 1;
        }

        const cl = &self.const_lines;
        try cl.appendSlice(self.gpa, "\n    .area CSEG (CODE)\n");
        try cl.appendSlice(self.gpa, sym);
        try cl.appendSlice(self.gpa, ":\n");
        var k: usize = 0;
        while (k < buf.len) : (k += 16) {
            const end = @min(k + 16, buf.len);
            try cl.appendSlice(self.gpa, "    .db ");
            for (buf[k..end], 0..) |b, j| {
                if (j != 0) try cl.append(self.gpa, ',');
                try cl.print(self.gpa, "0x{X:0>2}", .{b});
            }
            try cl.append(self.gpa, '\n');
        }
        return sym;
    }

    /// `&f` 的函数符号（与直调同一个 `_<fqn>`）：函数地址当值用。
    fn fnNavSym(self: *Lower, ref: Air.Inst.Ref) ?[]const u8 {
        const ip_index = ref.toInterned() orelse return null;
        const key = self.zcu.intern_pool.indexToKey(ip_index);
        const ptr = switch (key) {
            .ptr => |p| p,
            else => return null,
        };
        const nav_i = switch (ptr.base_addr) {
            .nav => |n| n,
            else => return null,
        };
        const nav = self.zcu.intern_pool.getNav(nav_i);
        const res = nav.resolved orelse return null;
        if (Type.fromInterned(res.type).zigTypeTag(self.zcu) != .@"fn") return null;
        const mangled = mangleNavSymbol(self.gpa, &self.zcu.intern_pool, nav_i) catch return null;
        defer self.gpa.free(mangled);
        return self.internSym(mangled);
    }
    /// 符号地址解引用：ptr 的基址是 `.nav`（全局/静态变量）→ (符号名, 字节偏移)。
    /// 函数不进这条路（`&f` 当值另有处理）。符号名与全局变量声明同源（`_<fqn>`）。
    /// `is_code = true` 表示这是 `const`（值在代码段，只能 `movc` 读、不能写）。
    fn constPtrSym(self: *Lower, ref: Air.Inst.Ref) ?struct { sym: []const u8, off: u64, is_code: bool } {
        const ip_index = ref.toInterned() orelse return null;
        const key = self.zcu.intern_pool.indexToKey(ip_index);
        const ptr = switch (key) {
            .ptr => |p| p,
            else => return null,
        };
        const nav_i = switch (ptr.base_addr) {
            .nav => |n| n,
            else => return null,
        };
        const nav = self.zcu.intern_pool.getNav(nav_i);
        const res = nav.resolved orelse return null;
        // 函数的 nav 类型是 fn：那是函数地址（M2.6b 的直调路径），不是数据基址。
        if (Type.fromInterned(res.type).zigTypeTag(self.zcu) == .@"fn") return null;
        // 全局变量的**声明**符号是「`_` + 未限定名」（与函数不同：函数用 `_<fqn>`
        // 且另发 `_<导出名>` 别名），所以这里必须按变量声明的方式拼同一个名字。
        const bare = nav.name.toSlice(&self.zcu.intern_pool);
        const tmp = std.fmt.allocPrint(self.gpa, "_{s}", .{bare}) catch return null;
        defer self.gpa.free(tmp);
        const sym = self.internSym(tmp) orelse return null;
        return .{ .sym = sym, .off = ptr.byte_offset, .is_code = res.@"const" };
    }

    /// 指针引用：固定地址 / 符号基址 / 已记录下来的「基址 + 运行期下标」。
    fn ptrRefOf(self: *Lower, ref: Air.Inst.Ref) ?PtrRef {
        if (self.constPtrAddr(ref)) |addr| return .{ .fixed = addr };
        if (self.constPtrSym(ref)) |s| {
            return if (s.is_code)
                .{ .code_sym = .{ .sym = s.sym, .off = s.off } }
            else
                .{ .sym_off = .{ .sym = s.sym, .off = s.off } };
        }
        const idx = ref.toIndex() orelse return null;
        return self.ptr_vals[@backingInt(idx)];
    }

    /// 读指针 pr 的第 k 字节到槽 dst（四种基址形态统一在这里）。
    fn emitLoadByte(self: *Lower, pr: PtrRef, k: u8, dst: u8) codegen.Error!void {
        switch (pr) {
            .fixed => |base| {
                const a = base + k;
                if (a <= 0xFF) {
                    try self.ops.append(self.gpa, .{ .load_dir = .{ .dst = mcsmir.v(dst), .addr = @intCast(a) } });
                } else if (a <= 0xFFFF) {
                    try self.ops.append(self.gpa, .{ .load_xdata = .{ .dst = mcsmir.v(dst), .addr = @intCast(a) } });
                } else return self.fail("固定地址 0x{X} 超出 51 可寻址范围", .{a});
            },
            .sym_off => |s| try self.ops.append(self.gpa, .{ .load_xdata_sym = .{
                .dst = mcsmir.v(dst),
                .sym = s.sym,
                .off = @intCast(s.off + k),
            } }),
            .elem => |e| {
                if (e.base <= 0xFF) return self.fail("直址（≤0xFF）暂不支持运行期下标：需要 @r0/@r1 间接寻址", .{});
                if (e.base + k > 0xFFFF) return self.fail("下标基址 0x{X} 超出 51 可寻址范围", .{e.base + k});
                try self.ops.append(self.gpa, .{ .load_xdata_idx = .{
                    .dst = mcsmir.v(dst),
                    .base = @intCast(e.base + k),
                    .idx = e.idx,
                    .scale = e.scale,
                } });
            },
            .elem_sym => |e| try self.ops.append(self.gpa, .{ .load_xdata_idx_sym = .{
                .dst = mcsmir.v(dst),
                .sym = e.sym,
                .off = @intCast(e.off + k),
                .idx = e.idx,
                .scale = e.scale,
            } }),
            .code_sym => |s| try self.ops.append(self.gpa, .{ .load_code_sym = .{
                .dst = mcsmir.v(dst),
                .sym = s.sym,
                .off = @intCast(s.off + k),
            } }),
            .code_elem_sym => |e| try self.ops.append(self.gpa, .{ .load_code_idx_sym = .{
                .dst = mcsmir.v(dst),
                .sym = e.sym,
                .off = @intCast(e.off + k),
                .idx = e.idx,
                .scale = e.scale,
            } }),
        }
    }

    /// 把 src 写进指针 pr 的第 k 字节。
    fn emitStoreByte(self: *Lower, pr: PtrRef, k: u8, src: Loc) codegen.Error!void {
        switch (pr) {
            .fixed => |base| {
                const a = base + k;
                if (a <= 0xFF) {
                    try self.ops.append(self.gpa, .{ .store_dir = .{ .addr = @intCast(a), .src = src } });
                } else if (a <= 0xFFFF) {
                    try self.ops.append(self.gpa, .{ .store_xdata = .{ .addr = @intCast(a), .src = src } });
                } else return self.fail("固定地址 0x{X} 超出 51 可寻址范围", .{a});
            },
            .sym_off => |s| try self.ops.append(self.gpa, .{ .store_xdata_sym = .{
                .sym = s.sym,
                .off = @intCast(s.off + k),
                .src = src,
            } }),
            .elem => |e| {
                if (e.base <= 0xFF) return self.fail("直址（≤0xFF）暂不支持运行期下标：需要 @r0/@r1 间接寻址", .{});
                if (e.base + k > 0xFFFF) return self.fail("下标基址 0x{X} 超出 51 可寻址范围", .{e.base + k});
                try self.ops.append(self.gpa, .{ .store_xdata_idx = .{
                    .base = @intCast(e.base + k),
                    .idx = e.idx,
                    .src = src,
                    .scale = e.scale,
                } });
            },
            .elem_sym => |e| try self.ops.append(self.gpa, .{ .store_xdata_idx_sym = .{
                .sym = e.sym,
                .off = @intCast(e.off + k),
                .idx = e.idx,
                .src = src,
                .scale = e.scale,
            } }),
            .code_sym, .code_elem_sym =>
                return self.fail("`const` 表在代码段（movc 只读）：不能写入。要可变就声明成 var", .{}),
        }
    }

    /// 整个编译单元是否出现会写 DPL/DPH 的指令（保守：多算几个函数只多花 3 字节）。
    /// **调用也算**：`lcall` 会把被调方的 arg0 放进 DPL（arg2 进 B），
    /// 而本函数的 1 字节 arg0 平时是「就地当 DPL」用的——不先搬进槽，
    /// 调用之后再用参数就变成上次的实参（真程序 puthex/putbyte 一撞就中）。
    fn airNeedsDptr(self: *Lower) bool {
        const tags = self.air.instructions.items(.tag);
        const datas = self.air.instructions.items(.data);
        for (tags, 0..) |t, i| switch (t) {
            .ptr_elem_ptr, .ptr_elem_val, .array_elem_val => return true,
            .call, .call_always_tail, .call_never_tail, .call_never_inline => return true,
            .load => if (self.constPtrAddr(datas[i].ty_op.operand) != null or
                self.constPtrSym(datas[i].ty_op.operand) != null) return true,
            .store => if (self.constPtrAddr(datas[i].bin_op.lhs) != null or
                self.constPtrSym(datas[i].bin_op.lhs) != null) return true,
            else => {},
        };
        return false;
    }

    /// 编译期 u8 常量（用于把常量下标折进固定地址、switch 的 case 值）。
    /// 也认 **enum 值**（`switch (e) { .start => … }` 的 case 项是 enum 标签）。
    fn constU8(self: *Lower, ref: Air.Inst.Ref) ?u8 {
        const ip_index = ref.toInterned() orelse return null;
        const ip = &self.zcu.intern_pool;
        var key = ip.indexToKey(ip_index);
        if (key == .enum_tag) key = ip.indexToKey(key.enum_tag.int);
        return switch (key) {
            .int => |int| switch (int.storage) {
                .u64 => |v| if (v <= 0xFF) @as(u8, @intCast(v)) else null,
                .i64 => |v| if (v >= 0 and v <= 0xFF) @as(u8, @intCast(v)) else null,
                else => null,
            },
            else => null,
        };
    }

    /// 跳过调试指令，找下一条真正参与代码生成的指令下标。
    /// P1 的「紧邻」判断必须用它：Zig 常在 load 与 add 之间插 dbg_*。
    fn nextRealIdx(self: *Lower, body: []const Air.Inst.Index, idx: usize) ?usize {
        const tags = self.air.instructions.items(.tag);
        var j = idx + 1;
        while (j < body.len) : (j += 1) {
            switch (tags[@backingInt(body[j])]) {
                .dbg_stmt, .dbg_empty_stmt, .dbg_inline_block,
                .dbg_var_ptr, .dbg_var_val, .dbg_arg_inline => {},
                else => return j,
            }
        }
        return null;
    }

    // ---- 多字节（u16/u32）表示与固定模板 ----
    //
    // 约定：一个 u16 值放在**两个连续 vreg 槽**里（低字节在前），u32 四个；
    // 运算全部展开成固定指令序列（clr c + addc/subb 逐字节），不做类型系统。

    fn wideBytes(self: *Lower, ty: Type) ?u8 {
        if (ty.zigTypeTag(self.zcu) != .int) return null;
        const bits = ty.bitSize(self.zcu);
        if (bits == 8 or bits == 16 or bits == 32) return @intCast(bits / 8);
        return null;
    }

    const IntInfo = struct { bytes: u8, signed: bool };

    /// 不报错的宽度探测：非整数或非 8/16/32 位 → null。
    fn intInfo(self: *Lower, ty: Type) ?IntInfo {
        if (ty.zigTypeTag(self.zcu) != .int) return null;
        const w = self.wideBytes(ty) orelse return null;
        return .{ .bytes = w, .signed = ty.isSignedInt(self.zcu) };
    }

    /// 整数宽度闸门：只认 8/16/32 位（无符号 + 有符号），其余一律明确拒绝。
    /// 以前的 `wideBytes(ty) orelse 1` 会把 u1/u64/i8 静默当 1 字节算——
    /// 实测 u1 的 1+1 得到 2（正确应为 0），属于静默算错。
    fn requireIntWidth(self: *Lower, ty: Type, comptime what: []const u8) codegen.Error!IntInfo {
        if (ty.zigTypeTag(self.zcu) != .int) {
            return self.fail(what ++ "：只支持整数类型", .{});
        }
        const info = self.intInfo(ty) orelse return self.fail(
            what ++ "：只支持 8/16/32 位整数，当前 {d} 位",
            .{ty.bitSize(self.zcu)},
        );
        return info;
    }

    fn wideOf(self: *Lower, ref: Air.Inst.Ref) ?u16 {
        const idx = ref.toIndex() orelse return null;
        return self.wide[@backingInt(idx)];
    }

    /// 分配 n 个**连续**槽。temp=true 表示「本条指令用完就还」。
    fn allocSlots(self: *Lower, n: u8, temp: bool) !u8 {
        var base: u16 = 0;
        while (base + n <= self.nregs) : (base += 1) {
            var k: u8 = 0;
            var ok = true;
            while (k < n) : (k += 1) {
                if (self.slot_used[@intCast(base + k)]) {
                    ok = false;
                    break;
                }
            }
            if (!ok) continue;
            k = 0;
            while (k < n) : (k += 1) {
                self.slot_used[@intCast(base + k)] = true;
                self.wide_blk[@intCast(base + k)] = false;
            }
            if (temp) self.recordTemp(@intCast(base), n);
            return @intCast(base);
        }
        // 池里没有合适的连续段 → 从高水位往上扩
        const b = self.nregs;
        if (@as(u16, b) + n > 255) return self.fail("帧寄存器耗尽（M1 限制 255）", .{});
        var k2: u8 = 0;
        while (k2 < n) : (k2 += 1) {
            self.slot_used[@intCast(@as(u16, b) + k2)] = true;
            self.wide_blk[@intCast(@as(u16, b) + k2)] = false;
        }
        self.nregs = @intCast(@as(u16, b) + n);
        if (temp) self.recordTemp(b, n);
        return b;
    }

    fn recordTemp(self: *Lower, base: u8, n: u8) void {
        if (self.temp_n >= self.temp_runs.len) return;
        self.temp_runs[self.temp_n] = .{ .base = base, .n = n };
        self.temp_n += 1;
    }

    /// 把本条指令的临时槽还回池里（`emitBody` 每条指令结束时调用）。
    /// `keep` = 本条指令的结果槽：有些指令直接把 `wideOperand` 拷出来的那份**当结果**
    /// （`.ptr_from_int`/`.int_cast` 这类恒等转换），那一段必须留着，否则结果立刻被复写。
    fn flushTempsKeep(self: *Lower, keep: ?u8) void {
        var i: u8 = 0;
        while (i < self.temp_n) : (i += 1) {
            const r = self.temp_runs[i];
            if (keep) |kv| {
                if (kv >= r.base and kv < r.base +% r.n) continue;
            }
            var k: u8 = 0;
            while (k < r.n) : (k += 1) {
                self.slot_used[@intCast(@as(u16, r.base) + k)] = false;
                self.wide_blk[@intCast(@as(u16, r.base) + k)] = false;
            }
        }
        self.temp_n = 0;
    }

    /// 这条指令的结果槽（不是 vreg 就没有）。
    fn resultSlot(self: *Lower, inst: Air.Inst.Index) ?u8 {
        const v = self.vals[@backingInt(inst)] orelse return null;
        return switch (v) {
            .vreg => |x| x,
            else => null,
        };
    }

    /// 一块连续槽（函数结果的槽，不回收）
    fn allocWide(self: *Lower, n: u8) !u8 {
        const base = try self.allocSlots(n, false);
        var i: u8 = 0;
        while (i < n) : (i += 1) self.wide_blk[base + i] = true;
        return base;
    }

    /// 只在本条指令内有效的连续槽（`wideOperand` 的拷贝）。
    fn allocTempWide(self: *Lower, n: u8) !u8 {
        const base = try self.allocSlots(n, true);
        var i: u8 = 0;
        while (i < n) : (i += 1) self.wide_blk[base + i] = true;
        return base;
    }

    fn constWide(self: *Lower, ref: Air.Inst.Ref) ?u32 {
        const ip_index = ref.toInterned() orelse return null;
        const key = self.zcu.intern_pool.indexToKey(ip_index);
        return switch (key) {
            .int => |int| switch (int.storage) {
                .u64 => |v| if (v <= 0xFFFF_FFFF) @intCast(v) else null,
                // 有符号常量（负数）：按 32 位二补码位模式取低 4 字节。
                .i64 => |v| if (v >= -0x8000_0000 and v <= 0xFFFF_FFFF)
                    @truncate(@as(u64, @bitCast(v)))
                else
                    null,
                else => null,
            },
            else => null,
        };
    }

    fn movTo(self: *Lower, dst: u8, src: mcsmir.Byte) !void {
        try self.ops.append(self.gpa, .{ .mov = .{ .dst = mcsmir.v(dst), .src = src } });
    }

    fn immTo(self: *Lower, dst: u8, val: u8) !void {
        try self.ops.append(self.gpa, .{ .imm = .{ .dst = mcsmir.v(dst), .value = val } });
    }

    /// 把源类型的高位补进 dst 的 [from, n) 字节：有符号补符号位（sex 操作），否则补 0。
    fn fillHigh(self: *Lower, dst: u8, from: u8, n: u8, src_top: u8, signed: bool) !void {
        var i = from;
        if (signed) {
            const e = try self.allocVreg();
            try self.ops.append(self.gpa, .{ .sex = .{ .dst = mcsmir.v(e), .src = mcsmir.v(src_top) } });
            while (i < n) : (i += 1) try self.movTo(dst + i, mcsmir.v(e));
        } else {
            while (i < n) : (i += 1) try self.immTo(dst + i, 0);
        }
    }

    /// 运行期移位次数：复制源到 dst，再按「每轮 1 位」循环 cnt 次。
    /// cnt 要复制一份（dec_br_nz 会改写）；算术右移每轮把最高位补成符号
    /// ——单轮填充掩码恒为 0x80，比常量移位的「余位掩码」还简单。
    fn shiftRuntime(self: *Lower, dst: u8, a: u8, n: u8, cnt: mcsmir.Byte, left: bool, arith: bool) !void {
        var k: u8 = 0;
        while (k < n) : (k += 1) try self.movTo(dst + k, mcsmir.v(a + k));
        var sign_ext: ?u8 = null;
        if (!left and arith) {
            const e = try self.allocVreg();
            try self.ops.append(self.gpa, .{ .sex = .{ .dst = mcsmir.v(e), .src = mcsmir.v(a + (n - 1)) } });
            sign_ext = e;
        }
        const c = try self.allocVreg();
        try self.ops.append(self.gpa, .{ .mov = .{ .dst = mcsmir.v(c), .src = cnt } });
        const l_done = self.tempLabel();
        const l_loop = self.tempLabel();
        try self.ops.append(self.gpa, .{ .br_ifz = .{ .cond = mcsmir.v(c), .target = l_done } });
        try self.ops.append(self.gpa, .{ .label = l_loop });
        try self.ops.append(self.gpa, .{ .clr_c = {} });
        k = 0;
        while (k < n) : (k += 1) {
            const bidx = if (left) k else (n - 1 - k);
            try self.ops.append(self.gpa, if (left)
                .{ .rlc = .{ .dst = mcsmir.v(dst + bidx), .src = mcsmir.v(dst + bidx) } }
            else .{ .rrc = .{ .dst = mcsmir.v(dst + bidx), .src = mcsmir.v(dst + bidx) } });
        }
        if (sign_ext) |e| {
            const l_skip = self.tempLabel();
            try self.ops.append(self.gpa, .{ .br_ifz = .{ .cond = mcsmir.v(e), .target = l_skip } });
            const top = dst + (n - 1);
            try self.ops.append(self.gpa, .{ .or_ = .{ .dst = mcsmir.v(top), .lhs = mcsmir.v(top), .rhs = .{ .imm = 0x80 } } });
            try self.ops.append(self.gpa, .{ .label = l_skip });
        }
        try self.ops.append(self.gpa, .{ .dec_br_nz = .{ .dst = mcsmir.v(c), .target = l_loop } });
        try self.ops.append(self.gpa, .{ .label = l_done });
    }

    /// 多字节乘法（固定模板）：
    ///   n=2（16×16→16，3 次 MUL，展开）：结果的低 16 位
    ///     = lo(a0*b0) | ((hi(a0*b0) + lo(a0*b1) + lo(a1*b0)) << 8)。
    ///     交叉项只取**低**字节——它乘的是 256 的权重。
    ///   n=4（32×32→32 低半，移位加法循环，代码 ~55B）：
    ///     逐位取 a 的 MSB：dst <<= 1；位为 1 则 dst += b。
    ///     展开的 10 次 MUL 版本要 ~200B，51 上代码比周期贵，选循环。
    fn mulWide(self: *Lower, dst: u8, a: u8, b: u8, n: u8) !void {
        if (n == 2) {
            const t0 = try self.allocVreg();
            const t1 = try self.allocVreg();
            const t2 = try self.allocVreg();
            try self.ops.append(self.gpa, .{ .mul16 = .{ .lo = mcsmir.v(dst), .hi = mcsmir.v(t0), .lhs = mcsmir.v(a), .rhs = mcsmir.v(b) } });
            try self.ops.append(self.gpa, .{ .mul = .{ .dst = mcsmir.v(t1), .lhs = mcsmir.v(a), .rhs = mcsmir.v(b + 1) } });
            try self.ops.append(self.gpa, .{ .mul = .{ .dst = mcsmir.v(t2), .lhs = mcsmir.v(a + 1), .rhs = mcsmir.v(b) } });
            try self.ops.append(self.gpa, .{ .add = .{ .dst = mcsmir.v(dst + 1), .lhs = mcsmir.v(t0), .rhs = mcsmir.v(t1) } });
            try self.ops.append(self.gpa, .{ .add = .{ .dst = mcsmir.v(dst + 1), .lhs = mcsmir.v(dst + 1), .rhs = mcsmir.v(t2) } });
            return;
        }
        const t = try self.allocWide(n);
        const ctr = try self.allocVreg();
        var k: u8 = 0;
        while (k < n) : (k += 1) {
            try self.immTo(dst + k, 0);
            try self.movTo(t + k, mcsmir.v(a + k));
        }
        try self.immTo(ctr, n * 8);
        const l_loop = self.tempLabel();
        const l_skip = self.tempLabel();
        try self.ops.append(self.gpa, .{ .label = l_loop });
        // dst <<= 1（移出的最高位丢弃）
        try self.ops.append(self.gpa, .{ .clr_c = {} });
        k = 0;
        while (k < n) : (k += 1) {
            try self.ops.append(self.gpa, .{ .rlc = .{ .dst = mcsmir.v(dst + k), .src = mcsmir.v(dst + k) } });
        }
        // t <<= 1，C = a 的下一位（从最高位开始）
        try self.ops.append(self.gpa, .{ .clr_c = {} });
        k = 0;
        while (k < n) : (k += 1) {
            try self.ops.append(self.gpa, .{ .rlc = .{ .dst = mcsmir.v(t + k), .src = mcsmir.v(t + k) } });
        }
        try self.ops.append(self.gpa, .{ .br_c = .{ .target = l_skip, .on_set = false } });
        try self.ops.append(self.gpa, .{ .clr_c = {} });
        k = 0;
        while (k < n) : (k += 1) {
            try self.ops.append(self.gpa, .{ .addc = .{ .dst = mcsmir.v(dst + k), .lhs = mcsmir.v(dst + k), .rhs = mcsmir.v(b + k) } });
        }
        try self.ops.append(self.gpa, .{ .label = l_skip });
        try self.ops.append(self.gpa, .{ .dec_br_nz = .{ .dst = mcsmir.v(ctr), .target = l_loop } });
    }

    /// dst = -src（n 字节二补码取负）。调用方保证 C 已清；链内 mov a,#0 不动 C。
    fn negInto(self: *Lower, dst: u8, src: u8, n: u8) !void {
        try self.ops.append(self.gpa, .{ .clr_c = {} });
        var k: u8 = 0;
        while (k < n) : (k += 1) {
            try self.ops.append(self.gpa, .{ .subb = .{
                .dst = mcsmir.v(dst + k),
                .lhs = .{ .imm = 0 },
                .rhs = mcsmir.v(src + k),
            } });
        }
    }

    /// dst = |src|：先整体搬运；有符号时看最高字节符号位（sex → 0x00/0xFF），
    /// 非零才取负。dst 允许与 src 相同（逐字节读在前写在后）。
    fn absInto(self: *Lower, dst: u8, src: u8, n: u8, signed: bool) !void {
        var k: u8 = 0;
        while (k < n) : (k += 1) try self.movTo(dst + k, mcsmir.v(src + k));
        if (!signed) return;
        const sgn = try self.allocVreg();
        try self.ops.append(self.gpa, .{ .sex = .{ .dst = mcsmir.v(sgn), .src = mcsmir.v(src + (n - 1)) } });
        const skip = self.tempLabel();
        try self.ops.append(self.gpa, .{ .br_ifz = .{ .cond = mcsmir.v(sgn), .target = skip } });
        try self.negInto(dst, dst, n);
        try self.ops.append(self.gpa, .{ .label = skip });
    }

    /// 多字节除法（恢复法，8n 轮循环，代码 ~40n+40 B）：
    /// 每轮把 (r:q) 左移一位（C 是被除数的下一位）→ 试减 y；够减置商位，
    /// 不够减把 y 加回来（恢复法比重存法少一份 n 字节暂存）。
    /// 有符号：先取绝对值，最后按「商异或、余数随被除数」定符号（C 的截断语义）。
    fn divmodWide(self: *Lower, lhs: u8, rhs: u8, n: u8, signed: bool, want_quot: bool) !u8 {
        const q = try self.allocWide(n);
        const r = try self.allocWide(n);
        const y = try self.allocWide(n);
        try self.absInto(q, lhs, n, signed);
        try self.absInto(y, rhs, n, signed);
        var k: u8 = 0;
        while (k < n) : (k += 1) try self.immTo(r + k, 0);
        const ctr = try self.allocVreg();
        try self.immTo(ctr, n * 8);
        const l_loop = self.tempLabel();
        const l_restore = self.tempLabel();
        const l_next = self.tempLabel();
        try self.ops.append(self.gpa, .{ .label = l_loop });
        try self.ops.append(self.gpa, .{ .clr_c = {} });
        k = 0;
        while (k < n) : (k += 1) {
            try self.ops.append(self.gpa, .{ .rlc = .{ .dst = mcsmir.v(q + k), .src = mcsmir.v(q + k) } });
        }
        k = 0;
        while (k < n) : (k += 1) {
            try self.ops.append(self.gpa, .{ .rlc = .{ .dst = mcsmir.v(r + k), .src = mcsmir.v(r + k) } });
        }
        try self.ops.append(self.gpa, .{ .clr_c = {} });
        k = 0;
        while (k < n) : (k += 1) {
            try self.ops.append(self.gpa, .{ .subb = .{ .dst = mcsmir.v(r + k), .lhs = mcsmir.v(r + k), .rhs = mcsmir.v(y + k) } });
        }
        try self.ops.append(self.gpa, .{ .br_c = .{ .target = l_restore, .on_set = true } });
        try self.ops.append(self.gpa, .{ .or_ = .{ .dst = mcsmir.v(q), .lhs = mcsmir.v(q), .rhs = .{ .imm = 1 } } });
        try self.ops.append(self.gpa, .{ .br = l_next });
        try self.ops.append(self.gpa, .{ .label = l_restore });
        try self.ops.append(self.gpa, .{ .clr_c = {} });
        k = 0;
        while (k < n) : (k += 1) {
            try self.ops.append(self.gpa, .{ .addc = .{ .dst = mcsmir.v(r + k), .lhs = mcsmir.v(r + k), .rhs = mcsmir.v(y + k) } });
        }
        try self.ops.append(self.gpa, .{ .label = l_next });
        try self.ops.append(self.gpa, .{ .dec_br_nz = .{ .dst = mcsmir.v(ctr), .target = l_loop } });
        if (signed) {
            const sa = try self.allocVreg();
            const sb = try self.allocVreg();
            try self.ops.append(self.gpa, .{ .sex = .{ .dst = mcsmir.v(sa), .src = mcsmir.v(lhs + (n - 1)) } });
            try self.ops.append(self.gpa, .{ .sex = .{ .dst = mcsmir.v(sb), .src = mcsmir.v(rhs + (n - 1)) } });
            const skip = self.tempLabel();
            if (want_quot) {
                // 商 = -(q) 当且仅当两侧符号不同
                try self.ops.append(self.gpa, .{ .xor_ = .{ .dst = mcsmir.v(sa), .lhs = mcsmir.v(sa), .rhs = mcsmir.v(sb) } });
                try self.ops.append(self.gpa, .{ .br_ifz = .{ .cond = mcsmir.v(sa), .target = skip } });
                try self.negInto(q, q, n);
            } else {
                // 余数符号跟着被除数
                try self.ops.append(self.gpa, .{ .br_ifz = .{ .cond = mcsmir.v(sa), .target = skip } });
                try self.negInto(r, r, n);
            }
            try self.ops.append(self.gpa, .{ .label = skip });
        }
        return if (want_quot) q else r;
    }

    /// 把一个操作数准备成 n 个连续槽位，返回基址。
    /// 变宽时按来源类型的符号性补位：无符号补 0，有符号补符号位——
    /// 这就是 i8→i16→i32 的符号扩展，也是负数常量变宽的位模式来源。
    fn wideOperand(self: *Lower, ref: Air.Inst.Ref, n: u8) !u8 {
        const sgn = blk: {
            const ty = self.air.typeOf(ref, &self.zcu.intern_pool);
            break :blk ty.zigTypeTag(self.zcu) == .int and ty.isSignedInt(self.zcu);
        };
        if (self.wideOf(ref)) |w| {
            const base: u8 = @truncate(w & 0xFF);
            const wn: u8 = @truncate(w >> 8);
            if (wn == n) return base;
            // 变宽拷出来的这份是**临时**：本条指令用完就还池（emitBody 每条指令 flush）
            const dst = try self.allocTempWide(n);
            var i: u8 = 0;
            while (i < wn and i < n) : (i += 1) try self.movTo(dst + i, mcsmir.v(base + i));
            if (wn < n) try self.fillHigh(dst, wn, n, base + (wn - 1), sgn);
            return dst;
        }
        if (self.constWide(ref)) |v| {
            const dst = try self.allocTempWide(n);
            var i: u8 = 0;
            while (i < n) : (i += 1) {
                const b: u8 = @truncate(v >> @intCast(8 * @as(u32, i)));
                try self.ops.append(self.gpa, .{ .imm = .{ .dst = mcsmir.v(dst + i), .value = b } });
            }
            return dst;
        }
        // 单字节值（u8/i8 提升到 16/32 位）：低字节搬过去，高位按符号性补。
        const loc = try self.refLoc(ref);
        const dst = try self.allocTempWide(n);
        try self.movTo(dst, loc);
        try self.fillHigh(dst, 1, n, dst, sgn);
        return dst;
    }

    fn fail(self: *Lower, comptime fmt: []const u8, args: anytype) codegen.Error {
        return self.zcu.codegenFail(self.nav, "mcs2: " ++ fmt, args);
    }

    fn allocVreg(self: *Lower) !u8 {
        return self.allocSlots(1, false);
    }

    fn typeIsU8(self: *Lower, ty: Type) bool {
        return ty.zigTypeTag(self.zcu) == .int and
            ty.bitSize(self.zcu) == 8 and
            !ty.isSignedInt(self.zcu);
    }

    /// Ref → 位置。常量 u8 物化为 imm；其余必须指向已处理的指令。
    fn refLoc(self: *Lower, ref: Air.Inst.Ref) codegen.Error!Loc {
        const ip = &self.zcu.intern_pool;
        if (ref.toInterned()) |ip_index| {
            // 编译期常量：仅支持 u8 立即数。
            const key = ip.indexToKey(ip_index);
            switch (key) {
                .int => |int| switch (int.storage) {
                    .u64 => |v| {
                        if (v > 0xFF) return self.fail("M1 常量仅支持 u8", .{});
                        // P1.5：常量直接当立即数操作数，不再物化到 vreg。
                        return .{ .imm = @intCast(v) };
                    },
                    else => return self.fail("M1 常量仅支持 u8 立即数", .{}),
                },
                else => return self.fail("M1 不支持该编译期引用形态", .{}),
            }
        }
        const idx = ref.toIndex() orelse return self.fail("M1：无法解析的操作数引用", .{});
        const loc = self.vals[@backingInt(idx)] orelse
            return self.fail("操作数 v{d} 尚无位置（内部错误）", .{@backingInt(idx)});
        return loc;
    }


    // ==== M2：控制流 ====

    fn labelReferenced(self: *Lower, id: u32) bool {
        for (self.ops.items) |op| switch (op) {
            .br => |t| if (t == id) return true,
            .br_ifnz => |x| if (x.target == id) return true,
            .br_ifz => |x| if (x.target == id) return true,
            .cmp_br => |x| if (x.target == id) return true,
            .dec_br_nz => |x| if (x.target == id) return true,
            else => {},
        };
        return false;
    }

    fn blockHead(self: *Lower, inst: Air.Inst.Index) u32 {
        return self.label_base + @as(u32, @backingInt(inst)) * 2;
    }

    fn blockEnd(self: *Lower, inst: Air.Inst.Index) u32 {
        return self.label_base + @as(u32, @backingInt(inst)) * 2 + 1;
    }

    fn tempLabel(_: *Lower) u32 {
        const l = session_temp_base;
        session_temp_base += 1;
        return l;
    }

    /// 这个块是否有结果槽（带返回值的块）；没有就是普通块。
    fn slotForBlock(self: *Lower, blk: Air.Inst.Index) ?BlockSlot {
        for (self.block_slots.items) |s| if (s.inst == blk) return s;
        return null;
    }

    /// `switch` 降级成「比较链 + 各分支体」：
    ///   判定值 == 某个 case 项（或落在某个范围）→ 跳到该分支体；都不中就执行 else 体。
    /// 分支体末尾统一跳到 switch 结束标签（体自己终结的除外）。
    /// 现在只支持 **1 字节判定值**（u8 / ≤256 的 enum）——命令分派就是这个形状。
    fn emitSwitch(self: *Lower, inst: Air.Inst.Index) codegen.Error!void {
        const us = self.air.unwrapSwitch(inst);
        const cond_ty = self.air.typeOf(us.operand, &self.zcu.intern_pool);
        const n = try self.storageBytes(cond_ty, "switch 判定值");
        if (n != 1) return self.fail("switch 的判定值暂时只支持 8 位（u8 / ≤256 的 enum）", .{});
        const cond = try self.refLoc(us.operand);

        const CaseRec = struct {
            label: u32,
            items: []const Air.Inst.Ref,
            ranges: []const [2]Air.Inst.Ref,
            body: []const Air.Inst.Index,
        };
        var cases: std.ArrayListUnmanaged(CaseRec) = .empty;
        defer cases.deinit(self.gpa);

        var it = us.iterateCases();
        while (it.next()) |c| {
            try cases.append(self.gpa, .{
                .label = self.tempLabel(),
                .items = c.items,
                .ranges = c.ranges,
                .body = c.body,
            });
        }
        const else_body = it.elseBody();
        const end_l = self.tempLabel();

        // ① 比较链
        for (cases.items) |c| {
            for (c.items) |item| {
                const v = self.constU8(item) orelse
                    return self.fail("switch 的 case 值必须是 8 位以内的整数常量", .{});
                try self.ops.append(self.gpa, .{ .cmp_br = .{
                    .lhs = cond,
                    .rhs = .{ .imm = v },
                    .cc = .eq,
                    .target = c.label,
                } });
            }
            for (c.ranges) |r| {
                const lo = self.constU8(r[0]) orelse
                    return self.fail("switch 的 case 范围必须是 8 位以内的整数常量", .{});
                const hi = self.constU8(r[1]) orelse
                    return self.fail("switch 的 case 范围必须是 8 位以内的整数常量", .{});
                // cond < lo → 跳过这个范围；再 cond <= hi → 命中
                const skip = self.tempLabel();
                try self.ops.append(self.gpa, .{ .cmp_br = .{
                    .lhs = cond,
                    .rhs = .{ .imm = lo },
                    .cc = .lt,
                    .target = skip,
                } });
                try self.ops.append(self.gpa, .{ .cmp_br = .{
                    .lhs = cond,
                    .rhs = .{ .imm = hi },
                    .cc = .le,
                    .target = c.label,
                } });
                try self.ops.append(self.gpa, .{ .label = skip });
            }
        }

        // ② else 分支（没写 else 就直接落到结束）
        if (else_body.len != 0) {
            const term = try self.emitBody(else_body);
            if (!term) try self.ops.append(self.gpa, .{ .br = end_l });
        } else {
            try self.ops.append(self.gpa, .{ .br = end_l });
        }

        // ③ 各分支体
        for (cases.items) |c| {
            try self.ops.append(self.gpa, .{ .label = c.label });
            const term = try self.emitBody(c.body);
            if (!term) try self.ops.append(self.gpa, .{ .br = end_l });
        }
        try self.ops.append(self.gpa, .{ .label = end_l });
    }

    fn ccOf(tag: Air.Inst.Tag) ?mcsmir.Cc {
        return switch (tag) {
            .cmp_lt, .cmp_lt_optimized => .lt,
            .cmp_lte, .cmp_lte_optimized => .le,
            .cmp_gt, .cmp_gt_optimized => .gt,
            .cmp_gte, .cmp_gte_optimized => .ge,
            .cmp_eq, .cmp_eq_optimized => .eq,
            .cmp_neq, .cmp_neq_optimized => .ne,
            else => null,
        };
    }

    /// cond_br：优先把“比较 → 分支”融合成 cmp_br（M2 第一刀）；
    /// 否则按字节测零（br_ifz）。条件为编译期常量时直接发单边。



    /// P1：数一数某条指令的值在 body 里被用了几次（跳过 skip 位置）。
    fn useCount(self: *Lower, body: []const Air.Inst.Index, target: Air.Inst.Index, skip: usize) usize {
        var n: usize = 0;
        for (body, 0..) |ins, k| {
            if (k == skip) continue;
            const tag = self.air.instructions.items(.tag)[@backingInt(ins)];
            const d = self.air.instructions.items(.data)[@backingInt(ins)];
            var hit = false;
            switch (tag) {
                .add, .add_safe, .add_wrap, .sub, .sub_safe, .sub_wrap, .store, .store_safe => {
                    if (d.bin_op.lhs.toIndex()) |x| {
                        if (@backingInt(x) == @backingInt(target)) hit = true;
                    }
                    if (d.bin_op.rhs.toIndex()) |x| {
                        if (@backingInt(x) == @backingInt(target)) hit = true;
                    }
                },
                .cmp_lt, .cmp_lte, .cmp_gt, .cmp_gte, .cmp_eq, .cmp_neq => {
                    if (d.bin_op.lhs.toIndex()) |x| {
                        if (@backingInt(x) == @backingInt(target)) hit = true;
                    }
                    if (d.bin_op.rhs.toIndex()) |x| {
                        if (@backingInt(x) == @backingInt(target)) hit = true;
                    }
                },
                // 单操作数消费者：比较结果被 return / 转换 / 取反直接吃掉时也算「当值用」。
                .ret, .ret_safe => {
                    if (d.un_op.toIndex()) |x| {
                        if (@backingInt(x) == @backingInt(target)) hit = true;
                    }
                },
                .int_cast, .int_cast_safe, .trunc, .not, .bit_cast => {
                    if (d.ty_op.operand.toIndex()) |x| {
                        if (@backingInt(x) == @backingInt(target)) hit = true;
                    }
                },
                else => {},
            }
            if (hit) n += 1;
        }
        return n;
    }

    // ==== M2.4：循环旋转 → djnz ====
    //
    // 目标形态：
    //   label L
    //   cmp_br(eq, i, 0 -> Lexit)      ; 顶部测试保留
    //   label Lbody                    ; 新增
    //     <body，去掉 sub i,#1>
    //   dec_br_nz(i, Lbody)            ; 替换原来的 br L
    //   label Lexit
    // 前置：body 里对 i 只有一处 imm 1 + sub i,i,1；只有一条 br L。

    fn vregOf(b: mcsmir.Byte) ?u8 {
        return switch (b) {
            .vreg => |r| r,
            else => null,
        };
    }

    fn refsVreg(op: mcsmir.Op, r: u8) bool {
        const eq = struct {
            fn f(x: mcsmir.Byte, rr: u8) bool {
                return switch (x) {
                    .vreg => |v| v == rr,
                    else => false,
                };
            }
        }.f;
        return switch (op) {
            .imm => |x| eq(x.dst, r),
            .add => |x| eq(x.dst, r) or eq(x.lhs, r) or eq(x.rhs, r),
            .sub => |x| eq(x.dst, r) or eq(x.lhs, r) or eq(x.rhs, r),
            .dec => |d| d == r,
            .mov => |x| eq(x.dst, r) or eq(x.src, r),
            .load_dir => |x| eq(x.dst, r),
            .store_dir => |x| eq(x.src, r),
            .store_xdata => |x| eq(x.src, r),
            .load_xdata => |x| eq(x.dst, r),
            .br_ifnz => |x| eq(x.cond, r),
            .br_ifz => |x| eq(x.cond, r),
            .cmp_br => |x| eq(x.lhs, r) or eq(x.rhs, r),
            .dec_br_nz => |x| eq(x.dst, r),
            .push => |x| eq(x.src, r),
            .pop => |x| eq(x.dst, r),
            else => false,
        };
    }

    /// 从 upto 往前找最近一次写 r 的指令，要求是 imm 0。
    fn isZeroAt(self: *Lower, r: u8, upto: usize) bool {
        var i = upto;
        while (i > 0) {
            i -= 1;
            switch (self.ops.items[i]) {
                .imm => |x| if (vregOf(x.dst)) |d| {
                    if (d == r) return x.value == 0;
                },
                .mov => |x| if (vregOf(x.dst)) |d| {
                    if (d == r) return false;
                },
                .add => |y| if (vregOf(y.dst)) |d| {
                    if (d == r) return false;
                },
                .sub => |y| if (vregOf(y.dst)) |d| {
                    if (d == r) return false;
                },
                .load_dir => |y| if (vregOf(y.dst)) |d| {
                    if (d == r) return false;
                },
                .load_xdata => |y| if (vregOf(y.dst)) |d| {
                    if (d == r) return false;
                },
                .dec => |d| if (d == r) return false,
                else => {},
            }
        }
        return false;
    }

    // ==== 位运算：SFR/直址的 RMW 折叠 ====
    //
    // `SCON.* |= 0x02` 会降成 load_dir + or_ + store_dir 三条；8051 有单指令 RMW，
    // 折回 dir 级后发射层就能出 `setb 0x99` / `orl 0x98,#0x03`（2-3B 而非 6B）。
    fn foldDirRmw(self: *Lower) void {
        var i: usize = 0;
        while (i + 2 < self.ops.items.len) : (i += 1) {
            const ld = switch (self.ops.items[i]) {
                .load_dir => |x| x,
                else => continue,
            };
            const v1 = vregOfByte(ld.dst) orelse continue;
            const second = self.ops.items[i + 1];
            const v2: u8 = blk: {
                switch (second) {
                    .or_ => |x| {
                        if (!sameVregByte(x.lhs, v1)) break :blk 255;
                        break :blk vregOfByte(x.dst) orelse 255;
                    },
                    .and_ => |x| {
                        if (!sameVregByte(x.lhs, v1)) break :blk 255;
                        break :blk vregOfByte(x.dst) orelse 255;
                    },
                    .xor_ => |x| {
                        if (!sameVregByte(x.lhs, v1)) break :blk 255;
                        break :blk vregOfByte(x.dst) orelse 255;
                    },
                    else => continue,
                }
            };
            if (v2 == 255) continue;
            const st = switch (self.ops.items[i + 2]) {
                .store_dir => |x| x,
                else => continue,
            };
            if (st.addr != ld.addr or !sameVregByte(st.src, v2)) continue;
            if (readCountVreg(self.ops.items, v1) != 1 or readCountVreg(self.ops.items, v2) != 1) continue;

            const dir_self = mcsmir.Byte{ .dir = ld.addr };
            self.ops.items[i] = switch (second) {
                .or_ => |x| mcsmir.Op{ .or_ = .{ .dst = dir_self, .lhs = dir_self, .rhs = x.rhs } },
                .and_ => |x| mcsmir.Op{ .and_ = .{ .dst = dir_self, .lhs = dir_self, .rhs = x.rhs } },
                .xor_ => |x| mcsmir.Op{ .xor_ = .{ .dst = dir_self, .lhs = dir_self, .rhs = x.rhs } },
                else => second,
            };
            var k = i + 1;
            while (k + 2 < self.ops.items.len) : (k += 1) self.ops.items[k] = self.ops.items[k + 2];
            self.ops.items.len -= 2;
        }
    }

    // ==== U2：位测试折叠 ====
    //
    // `(SCON & 0x02) != 0` 这一形态在 8051 上就是 `jb 0x99, L`。
    // 匹配：可选 load_dir{A} + and_{v,·,#m} + cmp_br{==0 / !=0, v, #0}，
    // 其中 m 是单比特、A 在 0x80-0xFF（SFR）或 0x20-0x2F（可位寻址 RAM）。
    // 位地址：SFR 区 = A + n（且 A 必须 8 字节对齐）；RAM 0x20-0x2F = (A-0x20)*8 + n。

    fn bitAddrOf(addr: u8, mask: u8) ?u8 {
        if (mask == 0) return null;
        if ((mask & (mask - 1)) != 0) return null; // 必须只有一个位
        const n: u8 = @intCast(@ctz(mask));
        // SFR 区：位地址 = SFR 地址 + 位号（SCON 0x98 的 TI → 0x99）。
        // 只有 8 字节对齐的 SFR 可位寻址。
        if (addr >= 0x80) {
            if (addr & 0x07 != 0) return null;
            return addr + n;
        }
        // 可位寻址 RAM 0x20-0x2F：位地址 = (addr-0x20)*8 + n
        if (addr >= 0x20 and addr <= 0x2F) return @intCast((@as(u16, addr - 0x20)) * 8 + n);
        return null;
    }

    fn foldBitTests(self: *Lower) void {
        var i: usize = 0;
        while (i < self.ops.items.len) : (i += 1) {
            if (i + 2 < self.ops.items.len) {
                const ld: ?@TypeOf(@as(mcsmir.Op, .{ .load_dir = .{ .dst = .{ .vreg = 0 }, .addr = 0 } }).load_dir) = switch (self.ops.items[i]) {
                    .load_dir => |x| x,
                    else => null,
                };
                if (ld) |l| {
                    const w = vregOfByte(l.dst);
                    const an: ?@TypeOf(@as(mcsmir.Op, .{ .and_ = .{ .dst = .{ .vreg = 0 }, .lhs = .{ .vreg = 0 }, .rhs = .{ .vreg = 0 } } }).and_) = switch (self.ops.items[i + 1]) {
                        .and_ => |x| x,
                        else => null,
                    };
                    const cb: ?@TypeOf(@as(mcsmir.Op, .{ .cmp_br = .{ .lhs = .{ .vreg = 0 }, .rhs = .{ .vreg = 0 }, .cc = .eq, .target = 0 } }).cmp_br) = switch (self.ops.items[i + 2]) {
                        .cmp_br => |x| x,
                        else => null,
                    };
                    if (w != null and an != null and cb != null) {
                        const v = vregOfByte(an.?.dst);
                        const m: u8 = switch (an.?.rhs) {
                            .imm => |x| x,
                            else => 0xFF,
                        };
                        const zero: u8 = switch (cb.?.rhs) {
                            .imm => |x| x,
                            else => 0xFF,
                        };
                        var lhs_ok = false;
                        if (v) |vv| lhs_ok = sameVregByte(cb.?.lhs, vv);
                        if (v != null and sameVregByte(an.?.lhs, w.?) and lhs_ok and
                            zero == 0 and (cb.?.cc == .eq or cb.?.cc == .ne) and
                            readCountVreg(self.ops.items, v.?) == 1 and
                            readCountVreg(self.ops.items, w.?) == 1)
                        {
                            if (bitAddrOf(l.addr, m)) |bit| {
                                self.ops.items[i] = .{ .bit_br = .{ .bit = bit, .target = cb.?.target, .on_set = cb.?.cc == .ne } };
                                var k = i + 1;
                                while (k + 2 < self.ops.items.len) : (k += 1) self.ops.items[k] = self.ops.items[k + 2];
                                self.ops.items.len -= 2;
                                continue;
                            }
                        }
                    }
                }
            }
            if (i + 1 < self.ops.items.len) {
                const an: ?@TypeOf(@as(mcsmir.Op, .{ .and_ = .{ .dst = .{ .vreg = 0 }, .lhs = .{ .vreg = 0 }, .rhs = .{ .vreg = 0 } } }).and_) = switch (self.ops.items[i]) {
                    .and_ => |x| x,
                    else => null,
                };
                const cb: ?@TypeOf(@as(mcsmir.Op, .{ .cmp_br = .{ .lhs = .{ .vreg = 0 }, .rhs = .{ .vreg = 0 }, .cc = .eq, .target = 0 } }).cmp_br) = switch (self.ops.items[i + 1]) {
                    .cmp_br => |x| x,
                    else => null,
                };
                if (an != null and cb != null) {
                    const v = vregOfByte(an.?.dst);
                    const addr: ?u8 = switch (an.?.lhs) {
                        .dir => |a| a,
                        else => null,
                    };
                    const m: u8 = switch (an.?.rhs) {
                        .imm => |x| x,
                        else => 0xFF,
                    };
                    const zero: u8 = switch (cb.?.rhs) {
                        .imm => |x| x,
                        else => 0xFF,
                    };
                    var lhs_ok = false;
                    if (v) |vv| lhs_ok = sameVregByte(cb.?.lhs, vv);
                    if (v != null and addr != null and lhs_ok and zero == 0 and
                        (cb.?.cc == .eq or cb.?.cc == .ne) and
                        readCountVreg(self.ops.items, v.?) == 1)
                    {
                        if (bitAddrOf(addr.?, m)) |bit| {
                            self.ops.items[i] = .{ .bit_br = .{ .bit = bit, .target = cb.?.target, .on_set = cb.?.cc == .ne } };
                            var k = i + 1;
                            while (k + 1 < self.ops.items.len) : (k += 1) self.ops.items[k] = self.ops.items[k + 1];
                            self.ops.items.len -= 1;
                            continue;
                        }
                    }
                }
            }
        }
    }

    // ==== M2.13：寄存器分配（切片 1）====
    //
    // 只挑「自更新的热点值」（dst == lhs 的累加器/计数器）放进 R5/R6/R7。
    // 每个 vreg 独占一个寄存器，非映射值仍走 DSEG 槽 —— 因此不需要活跃期分析。
    // 前提：函数内没有 push/pop（ISR 现场保存），且不是中断函数本身
    //（ISR 只保存 A/PSW/DPL/DPH，不碰 R5-R7，所以主程序用寄存器是安全的）。

    fn sameVregByte(b: mcsmir.Byte, r: u8) bool {
        return switch (b) {
            .vreg => |v| v == r,
            else => false,
        };
    }

    fn vregOfByte(b: mcsmir.Byte) ?u8 {
        return switch (b) {
            .vreg => |v| v,
            else => null,
        };
    }

    fn isSelfUpdate(op: mcsmir.Op) ?u8 {
        return switch (op) {
            .add => |x| blk: {
                const v = vregOfByte(x.dst) orelse break :blk null;
                break :blk if (sameVregByte(x.lhs, v)) v else null;
            },
            .sub => |x| blk: {
                const v = vregOfByte(x.dst) orelse break :blk null;
                break :blk if (sameVregByte(x.lhs, v)) v else null;
            },
            .and_ => |x| blk: {
                const v = vregOfByte(x.dst) orelse break :blk null;
                break :blk if (sameVregByte(x.lhs, v)) v else null;
            },
            .or_ => |x| blk: {
                const v = vregOfByte(x.dst) orelse break :blk null;
                break :blk if (sameVregByte(x.lhs, v)) v else null;
            },
            .xor_ => |x| blk: {
                const v = vregOfByte(x.dst) orelse break :blk null;
                break :blk if (sameVregByte(x.lhs, v)) v else null;
            },
            .dec_br_nz => |x| vregOfByte(x.dst),
            else => null,
        };
    }

    fn mapByteVreg(b: mcsmir.Byte, map: *const [256]?u8) mcsmir.Byte {
        return switch (b) {
            .vreg => |v| if (map[v]) |reg| .{ .dir = reg } else b,
            else => b,
        };
    }

    fn mapOpVregs(op: mcsmir.Op, map: *const [256]?u8) mcsmir.Op {
        return switch (op) {
            .imm => |x| .{ .imm = .{ .dst = mapByteVreg(x.dst, map), .value = x.value } },
            .add => |x| .{ .add = .{ .dst = mapByteVreg(x.dst, map), .lhs = mapByteVreg(x.lhs, map), .rhs = mapByteVreg(x.rhs, map) } },
            .sub => |x| .{ .sub = .{ .dst = mapByteVreg(x.dst, map), .lhs = mapByteVreg(x.lhs, map), .rhs = mapByteVreg(x.rhs, map) } },
            .and_ => |x| .{ .and_ = .{ .dst = mapByteVreg(x.dst, map), .lhs = mapByteVreg(x.lhs, map), .rhs = mapByteVreg(x.rhs, map) } },
            .or_ => |x| .{ .or_ = .{ .dst = mapByteVreg(x.dst, map), .lhs = mapByteVreg(x.lhs, map), .rhs = mapByteVreg(x.rhs, map) } },
            .xor_ => |x| .{ .xor_ = .{ .dst = mapByteVreg(x.dst, map), .lhs = mapByteVreg(x.lhs, map), .rhs = mapByteVreg(x.rhs, map) } },
            .mul => |x| .{ .mul = .{ .dst = mapByteVreg(x.dst, map), .lhs = mapByteVreg(x.lhs, map), .rhs = mapByteVreg(x.rhs, map) } },
            .mul16 => |x| .{ .mul16 = .{
                .lo = mapByteVreg(x.lo, map),
                .hi = mapByteVreg(x.hi, map),
                .lhs = mapByteVreg(x.lhs, map),
                .rhs = mapByteVreg(x.rhs, map),
            } },
            .div_ => |x| .{ .div_ = .{ .dst = mapByteVreg(x.dst, map), .lhs = mapByteVreg(x.lhs, map), .rhs = mapByteVreg(x.rhs, map) } },
            .rem_ => |x| .{ .rem_ = .{ .dst = mapByteVreg(x.dst, map), .lhs = mapByteVreg(x.lhs, map), .rhs = mapByteVreg(x.rhs, map) } },
            .not_ => |x| .{ .not_ = .{ .dst = mapByteVreg(x.dst, map), .src = mapByteVreg(x.src, map) } },
            .addc => |x| .{ .addc = .{ .dst = mapByteVreg(x.dst, map), .lhs = mapByteVreg(x.lhs, map), .rhs = mapByteVreg(x.rhs, map) } },
            .rlc => |x| .{ .rlc = .{ .dst = mapByteVreg(x.dst, map), .src = mapByteVreg(x.src, map) } },
            .rrc => |x| .{ .rrc = .{ .dst = mapByteVreg(x.dst, map), .src = mapByteVreg(x.src, map) } },
            .subb => |x| .{ .subb = .{ .dst = mapByteVreg(x.dst, map), .lhs = mapByteVreg(x.lhs, map), .rhs = mapByteVreg(x.rhs, map) } },
            .clr_c => op,
            .shl => |x| .{ .shl = .{ .dst = mapByteVreg(x.dst, map), .lhs = mapByteVreg(x.lhs, map), .n = x.n } },
            .shr => |x| .{ .shr = .{ .dst = mapByteVreg(x.dst, map), .lhs = mapByteVreg(x.lhs, map), .n = x.n, .arith = x.arith } },
            .sex => |x| .{ .sex = .{ .dst = mapByteVreg(x.dst, map), .src = mapByteVreg(x.src, map) } },
            .cmp_wide_br => |x| .{ .cmp_wide_br = .{
                .lhs = x.lhs,
                .rhs = x.rhs,
                .n = x.n,
                .tmp = mapByteVreg(x.tmp, map),
                .cc = x.cc,
                .signed = x.signed,
                .target = x.target,
            } },
            .mov => |x| .{ .mov = .{ .dst = mapByteVreg(x.dst, map), .src = mapByteVreg(x.src, map) } },
            .load_dir => |x| .{ .load_dir = .{ .dst = mapByteVreg(x.dst, map), .addr = x.addr } },
            .store_dir => |x| .{ .store_dir = .{ .addr = x.addr, .src = mapByteVreg(x.src, map) } },
            .load_xdata => |x| .{ .load_xdata = .{ .dst = mapByteVreg(x.dst, map), .addr = x.addr } },
            .lea_dptr_sym => op,
            .store_xdata => |x| .{ .store_xdata = .{ .addr = x.addr, .src = mapByteVreg(x.src, map) } },
            .load_xdata_idx => |x| .{ .load_xdata_idx = .{ .dst = mapByteVreg(x.dst, map), .base = x.base, .idx = mapByteVreg(x.idx, map), .scale = x.scale } },
            .store_xdata_idx => |x| .{ .store_xdata_idx = .{ .base = x.base, .idx = mapByteVreg(x.idx, map), .src = mapByteVreg(x.src, map), .scale = x.scale } },
            .load_xdata_idx_sym => |x| .{ .load_xdata_idx_sym = .{ .dst = mapByteVreg(x.dst, map), .sym = x.sym, .idx = mapByteVreg(x.idx, map), .scale = x.scale } },
            .store_xdata_idx_sym => |x| .{ .store_xdata_idx_sym = .{ .sym = x.sym, .idx = mapByteVreg(x.idx, map), .src = mapByteVreg(x.src, map), .scale = x.scale } },
            .load_xdata_sym => |x| .{ .load_xdata_sym = .{ .dst = mapByteVreg(x.dst, map), .sym = x.sym, .off = x.off } },
            .load_code_sym => |x| .{ .load_code_sym = .{ .dst = mapByteVreg(x.dst, map), .sym = x.sym, .off = x.off } },
            .load_code_idx_sym => |x| .{ .load_code_idx_sym = .{ .dst = mapByteVreg(x.dst, map), .sym = x.sym, .off = x.off, .idx = mapByteVreg(x.idx, map), .scale = x.scale } },
            .store_xdata_sym => |x| .{ .store_xdata_sym = .{ .sym = x.sym, .off = x.off, .src = mapByteVreg(x.src, map) } },
            .br_ifnz => |x| .{ .br_ifnz = .{ .cond = mapByteVreg(x.cond, map), .target = x.target } },
            .br_ifz => |x| .{ .br_ifz = .{ .cond = mapByteVreg(x.cond, map), .target = x.target } },
            .cmp_br => |x| .{ .cmp_br = .{ .lhs = mapByteVreg(x.lhs, map), .rhs = mapByteVreg(x.rhs, map), .cc = x.cc, .target = x.target } },
            .dec_br_nz => |x| .{ .dec_br_nz = .{ .dst = mapByteVreg(x.dst, map), .target = x.target } },
            .br_c, .lcall => op,
            .lcall_ind => op,
            .push => |x| .{ .push = .{ .src = mapByteVreg(x.src, map) } },
            .pop => |x| .{ .pop = .{ .dst = mapByteVreg(x.dst, map) } },
            .dec => op, // 载荷是裸 vreg 下标；对应 vreg 已被禁用映射
            .bit_br => op,
            .label, .br, .ret, .reti, .halt => op,
        };
    }


    /// M2.14 切片 1：**基本块内的槽位复用**。
    /// 每个值原本独占一个（或一段连续）槽位；这里把「定义点到最后一次读都落在同一个
    /// 基本块内」（中间没有标签/跳转）的值，在它死之后把槽位让给后面的值。
    /// 跨标签/循环/分支的值一律**钉住**（不复用）——循环体内部的直线段仍然可复用，
    /// 因为下一轮会重新执行定义。
    fn reuseSlots(self: *Lower) void {
        const ops = self.ops.items;
        const n_ops = ops.len;
        if (n_ops == 0 or self.nregs == 0) return;
        const nv: usize = self.nregs;

        var def_at: [256]?usize = @splat(null);
        var last_read: [256]?usize = @splat(null);
        for (ops, 0..) |op, i| {
            var v: usize = 0;
            while (v < nv) : (v += 1) {
                const b: u8 = @intCast(v);
                if (writesVregOp(op, b) and def_at[v] == null) def_at[v] = i;
                if (readsVreg(op, b)) last_read[v] = i;
            }
        }

        // 基本块边界：这些 op 之后不允许跨值复用
        const is_boundary = struct {
            fn f(o: mcsmir.Op) bool {
                return switch (o) {
                    .label, .br, .br_ifnz, .br_ifz, .cmp_br, .dec_br_nz, .bit_br, .br_c, .ret, .reti, .halt, .lcall, .lcall_ind => true,
                    else => false,
                };
            }
        }.f;

        // 把「连续 wide_blk」的槽并成一组（多字节块必须整段连着搬）
        var group_of: [256]u16 = @splat(0xFFFF);
        var group_base: [256]u8 = @splat(0);
        var group_len: [256]u8 = @splat(1);
        var n_groups: usize = 0;
        var v: usize = 0;
        while (v < nv) {
            var len: usize = 1;
            if (self.wide_blk[v]) {
                while (v + len < nv and self.wide_blk[v + len]) len += 1;
            }
            group_base[n_groups] = @intCast(v);
            group_len[n_groups] = @intCast(len);
            var k: usize = 0;
            while (k < len) : (k += 1) group_of[v + k] = @intCast(n_groups);
            n_groups += 1;
            v += len;
        }

        // 逐组：定义点 = 组内最早，死亡点 = 组内最晚读；中间有边界就钉住
        var g_def: [256]usize = @splat(n_ops);
        var g_die: [256]usize = @splat(0);
        var g_pin: [256]bool = @splat(false);
        v = 0;
        while (v < nv) : (v += 1) {
            const g = group_of[v];
            if (def_at[v]) |d| {
                if (d < g_def[g]) g_def[g] = d;
            }
            if (last_read[v]) |l| {
                if (l > g_die[g]) g_die[g] = l;
            }
        }
        var g: usize = 0;
        while (g < n_groups) : (g += 1) {
            if (g_def[g] >= n_ops) {
                g_pin[g] = true;
                continue;
            }
            var i: usize = g_def[g] + 1;
            while (i < g_die[g] and i < n_ops) : (i += 1) {
                if (is_boundary(ops[i])) {
                    g_pin[g] = true;
                    break;
                }
            }
        }

        // 分配：按 op 顺序推进，槽位在组死亡后释放。
        // **从 8 号槽开始**：0x00–0x07 是 bank0 工作寄存器，`byteText` 会把 `.dir a<8`
        // 渲染成 `rN`（为了 1 字节编码）；复用出来的槽号如果落进 0–7，就会发出
        // `mov r2,r0` 这种 8051 不存在的指令（sdas: Invalid Addressing Mode）。
        var new_of_group: [256]u8 = @splat(0);
        var slot_free: [256]bool = @splat(true);
        var slot_die: [256]usize = @splat(0);
        var hi: usize = 8;
        var pin_hi: usize = 8;
        for (0..8) |r0| slot_free[r0] = false;
        i_loop: {
            var i: usize = 0;
            while (i < n_ops) : (i += 1) {
                // 释放已经死掉的槽位
                var s: usize = 0;
                while (s < hi) : (s += 1) {
                    if (!slot_free[s] and slot_die[s] <= i) slot_free[s] = true;
                }
                // 看看有没有组在这一条 op 上出生
                g = 0;
                while (g < n_groups) : (g += 1) {
                    if (g_def[g] != i) continue;
                    const len = group_len[g];
                    if (g_pin[g]) {
                        // 钉住的组：永远放在水线之上
                        if (pin_hi + len > 255) break :i_loop;
                        new_of_group[g] = @intCast(pin_hi);
                        s = pin_hi;
                        while (s < pin_hi + len) : (s += 1) {
                            slot_free[s] = false;
                            slot_die[s] = n_ops;
                        }
                        pin_hi += len;
                        if (pin_hi > hi) hi = pin_hi;
                    } else {
                        var base: usize = 8;
                        var found = false;
                        while (base + len <= hi) : (base += 1) {
                            var ok = true;
                            var k: usize = 0;
                            while (k < len) : (k += 1) {
                                if (!slot_free[base + k]) {
                                    ok = false;
                                    break;
                                }
                            }
                            if (ok) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) base = hi;
                        if (base + len > 255) break :i_loop;
                        new_of_group[g] = @intCast(base);
                        s = base;
                        while (s < base + len) : (s += 1) {
                            slot_free[s] = false;
                            slot_die[s] = if (g_die[g] > i) g_die[g] else i;
                        }
                        if (base + len > hi) hi = base + len;
                    }
                }
            }
        }

        if (hi == 0 or hi > 255) return;
        // 没缩水就别改（也避免把 assignRegisters 的既有结论打散）
        if (hi >= nv) return;

        var map: [256]?u8 = undefined;
        @memset(&map, null);
        v = 0;
        while (v < nv) : (v += 1) {
            const gg = group_of[v];
            map[v] = new_of_group[gg] + @as(u8, @intCast(v - group_base[gg]));
        }
        for (self.ops.items) |*op| op.* = mapOpVregs(op.*, &map);
        // `.dec` 的载荷是**裸 vreg 编号**（mapOpVregs 故意不动它），这里单独补一次；
        // 漏了它就会拿旧编号发 `dec _mcs_v<旧号>`，编号越界 → 汇编报错。
        for (self.ops.items) |*op| switch (op.*) {
            .dec => |r| {
                if (map[r]) |nw| op.* = .{ .dec = nw };
            },
            else => {},
        };
        // 重建 wide_blk（按新编号）
        self.wide_blk = @splat(false);
        g = 0;
        while (g < n_groups) : (g += 1) {
            if (group_len[g] < 2) continue;
            var k: u8 = 0;
            while (k < group_len[g]) : (k += 1) self.wide_blk[new_of_group[g] + k] = true;
        }
        self.nregs = @intCast(hi);
    }
    fn assignRegisters(self: *Lower) void {

        if (self.is_isr) return;
        for (self.ops.items) |op| switch (op) {
            .push, .pop => return,
            else => {},
        };

        var score: [256]u16 = undefined;
        @memset(&score, 0);
        var banned: [256]bool = undefined;
        @memset(&banned, false);
        // 多字节块必须保持连续直址：整块都不许映射到 rN。
        for (0..256) |vi| {
            if (self.wide_blk[vi]) banned[vi] = true;
        }
        for (self.ops.items) |op| switch (op) {
            .dec => |r| banned[r] = true,

            else => if (isSelfUpdate(op)) |v| {
                score[v] +|= 1;
            },
        };

        var picked: [3]u8 = undefined;
        var np: usize = 0;
        const regs = [3]u8{ 0x07, 0x06, 0x05 }; // R7 / R6 / R5
        while (np < 3) {
            var best: ?u8 = null;
            var best_score: u16 = 0;
            for (0..256) |vi| {
                const v: u8 = @intCast(vi);
                if (banned[v] or score[v] == 0) continue;
                var dup = false;
                for (picked[0..np]) |q| {
                    if (q == v) dup = true;
                }
                if (dup) continue;
                if (score[v] > best_score) {
                    best_score = score[v];
                    best = v;
                }
            }
            const b = best orelse break;
            picked[np] = b;
            np += 1;
        }
        if (np == 0) return;

        // 8051 **没有 `mov rN,rM`**：如果某个 mov 的两个操作数都被选进寄存器，
        // 就丢掉源那一个（reg→dir / dir→reg 都是合法指令，只有 reg→reg 不行）。
        var in_map: [256]bool = @splat(false);
        for (picked[0..np]) |v| in_map[v] = true;
        for (self.ops.items) |op| switch (op) {
            .mov => |x| {
                if (x.dst == .vreg and x.src == .vreg) {
                    if (in_map[x.dst.vreg] and in_map[x.src.vreg]) in_map[x.src.vreg] = false;
                }
            },
            else => {},
        };

        var map: [256]?u8 = undefined;
        @memset(&map, null);
        var slot: usize = 0;
        for (picked[0..np]) |v| {
            if (!in_map[v]) continue;
            map[v] = regs[slot];
            slot += 1;
        }
        for (self.ops.items) |*op| op.* = mapOpVregs(op.*, &map);
    }

    // ==== M2.12：相邻拷贝折叠 ====
    //
    // `mov vd,vs` 后紧跟唯一一次读 vd 的指令 → 把该操作数换成 vs，删掉 mov。
    // 只看紧邻、不跨标签/跳转，所以不需要活跃期分析；读次数 == 1 保证删掉 mov 不丢值。

    fn isVregByte(b: mcsmir.Byte, r: u8) bool {
        return switch (b) {
            .vreg => |v| v == r,
            else => false,
        };
    }

    fn readsVreg(op: mcsmir.Op, r: u8) bool {
        return switch (op) {
            .add => |x| isVregByte(x.lhs, r) or isVregByte(x.rhs, r),
            .sub => |x| isVregByte(x.lhs, r) or isVregByte(x.rhs, r),
            .and_ => |x| isVregByte(x.lhs, r) or isVregByte(x.rhs, r),
            .or_ => |x| isVregByte(x.lhs, r) or isVregByte(x.rhs, r),
            .xor_ => |x| isVregByte(x.lhs, r) or isVregByte(x.rhs, r),
            .mul => |x| isVregByte(x.lhs, r) or isVregByte(x.rhs, r),
            .div_ => |x| isVregByte(x.lhs, r) or isVregByte(x.rhs, r),
            .rem_ => |x| isVregByte(x.lhs, r) or isVregByte(x.rhs, r),
            .not_ => |x| isVregByte(x.src, r),
            .addc => |x| isVregByte(x.lhs, r) or isVregByte(x.rhs, r),
            .rlc => |x| isVregByte(x.src, r),
            .rrc => |x| isVregByte(x.src, r),
            .subb => |x| isVregByte(x.lhs, r) or isVregByte(x.rhs, r),
            .shl => |x| isVregByte(x.lhs, r),
            .shr => |x| isVregByte(x.lhs, r),
            .mov => |x| isVregByte(x.src, r),
            .cmp_br => |x| isVregByte(x.lhs, r) or isVregByte(x.rhs, r),
            .br_ifnz => |x| isVregByte(x.cond, r),
            .br_ifz => |x| isVregByte(x.cond, r),
            .push => |x| isVregByte(x.src, r),
            .store_dir => |x| isVregByte(x.src, r),
            .store_xdata => |x| isVregByte(x.src, r),
            .dec_br_nz => |x| isVregByte(x.dst, r),
            .load_xdata_idx => |x| isVregByte(x.idx, r),
            .store_xdata_idx => |x| isVregByte(x.idx, r) or isVregByte(x.src, r),
            .load_xdata_idx_sym => |x| isVregByte(x.idx, r),
            .store_xdata_idx_sym => |x| isVregByte(x.idx, r) or isVregByte(x.src, r),
            .store_xdata_sym => |x| isVregByte(x.src, r),
            .load_code_idx_sym => |x| isVregByte(x.idx, r),
            .dec => |v| v == r, // RMW：既读又写
            else => false,
        };
    }


    /// 这条 op 是否**写**某个 vreg（`dst`/`pop`/`dec_br_nz` 等）。与 readsVreg 对称。
    fn writesVregOp(op: mcsmir.Op, r: u8) bool {
        return switch (op) {
            .add => |x| isVregByte(x.dst, r),
            .sub => |x| isVregByte(x.dst, r),
            .and_ => |x| isVregByte(x.dst, r),
            .or_ => |x| isVregByte(x.dst, r),
            .xor_ => |x| isVregByte(x.dst, r),
            .mul => |x| isVregByte(x.dst, r),
            .div_ => |x| isVregByte(x.dst, r),
            .rem_ => |x| isVregByte(x.dst, r),
            .not_ => |x| isVregByte(x.dst, r),
            .addc => |x| isVregByte(x.dst, r),
            .subb => |x| isVregByte(x.dst, r),
            .rlc => |x| isVregByte(x.dst, r),
            .rrc => |x| isVregByte(x.dst, r),
            .shl => |x| isVregByte(x.dst, r),
            .shr => |x| isVregByte(x.dst, r),
            .mov => |x| isVregByte(x.dst, r),
            .imm => |x| isVregByte(x.dst, r),
            .load_dir => |x| isVregByte(x.dst, r),
            .load_xdata => |x| isVregByte(x.dst, r),
            .load_xdata_idx => |x| isVregByte(x.dst, r),
            .load_xdata_idx_sym => |x| isVregByte(x.dst, r),
            .load_xdata_sym => |x| isVregByte(x.dst, r),
            .load_code_sym => |x| isVregByte(x.dst, r),
            .load_code_idx_sym => |x| isVregByte(x.dst, r),
            .pop => |x| isVregByte(x.dst, r),
            .dec_br_nz => |x| isVregByte(x.dst, r),
            .dec => |v| v == r,
            .mul16 => |x| isVregByte(x.lo, r) or isVregByte(x.hi, r),
            .sex => |x| isVregByte(x.dst, r),
            .lcall_ind => |x| isVregByte(x.save, r),
            else => false,
        };
    }
    fn readCountVreg(ops: []const mcsmir.Op, r: u8) usize {

        var n: usize = 0;
        for (ops) |op| if (readsVreg(op, r)) {
            n += 1;
        };
        return n;
    }

    /// 把 op 里读 from 的操作数换成 to；无法替换（或属于写操作数）返回 null。
    fn substReadVreg(op: mcsmir.Op, from: u8, to: mcsmir.Byte) ?mcsmir.Op {
        return switch (op) {
            .mov => |x| if (isVregByte(x.src, from)) mcsmir.Op{ .mov = .{ .dst = x.dst, .src = to } } else null,
            .add => |x| blk: {
                var y = x;
                if (isVregByte(y.lhs, from)) y.lhs = to else if (isVregByte(y.rhs, from)) y.rhs = to else break :blk null;
                break :blk mcsmir.Op{ .add = y };
            },
            .sub => |x| blk: {
                var y = x;
                if (isVregByte(y.lhs, from)) y.lhs = to else if (isVregByte(y.rhs, from)) y.rhs = to else break :blk null;
                break :blk mcsmir.Op{ .sub = y };
            },
            .and_ => |x| blk: {
                var y = x;
                if (isVregByte(y.lhs, from)) y.lhs = to else if (isVregByte(y.rhs, from)) y.rhs = to else break :blk null;
                break :blk mcsmir.Op{ .and_ = y };
            },
            .or_ => |x| blk: {
                var y = x;
                if (isVregByte(y.lhs, from)) y.lhs = to else if (isVregByte(y.rhs, from)) y.rhs = to else break :blk null;
                break :blk mcsmir.Op{ .or_ = y };
            },
            .xor_ => |x| blk: {
                var y = x;
                if (isVregByte(y.lhs, from)) y.lhs = to else if (isVregByte(y.rhs, from)) y.rhs = to else break :blk null;
                break :blk mcsmir.Op{ .xor_ = y };
            },
            .mul => |x| blk: {
                var y = x;
                if (isVregByte(y.lhs, from)) y.lhs = to else if (isVregByte(y.rhs, from)) y.rhs = to else break :blk null;
                break :blk mcsmir.Op{ .mul = y };
            },
            .div_ => |x| blk: {
                var y = x;
                if (isVregByte(y.lhs, from)) y.lhs = to else if (isVregByte(y.rhs, from)) y.rhs = to else break :blk null;
                break :blk mcsmir.Op{ .div_ = y };
            },
            .rem_ => |x| blk: {
                var y = x;
                if (isVregByte(y.lhs, from)) y.lhs = to else if (isVregByte(y.rhs, from)) y.rhs = to else break :blk null;
                break :blk mcsmir.Op{ .rem_ = y };
            },
            .not_ => |x| if (isVregByte(x.src, from)) mcsmir.Op{ .not_ = .{ .dst = x.dst, .src = to } } else null,
            .rlc => |x| if (isVregByte(x.src, from)) mcsmir.Op{ .rlc = .{ .dst = x.dst, .src = to } } else null,
            .rrc => |x| if (isVregByte(x.src, from)) mcsmir.Op{ .rrc = .{ .dst = x.dst, .src = to } } else null,
            .addc => |x| blk: {
                var y = x;
                if (isVregByte(y.lhs, from)) y.lhs = to else if (isVregByte(y.rhs, from)) y.rhs = to else break :blk null;
                break :blk mcsmir.Op{ .addc = y };
            },
            .subb => |x| blk: {
                var y = x;
                if (isVregByte(y.lhs, from)) y.lhs = to else if (isVregByte(y.rhs, from)) y.rhs = to else break :blk null;
                break :blk mcsmir.Op{ .subb = y };
            },
            .shl => |x| if (isVregByte(x.lhs, from)) mcsmir.Op{ .shl = .{ .dst = x.dst, .lhs = to, .n = x.n } } else null,
            .shr => |x| if (isVregByte(x.lhs, from)) mcsmir.Op{ .shr = .{ .dst = x.dst, .lhs = to, .n = x.n } } else null,
            .cmp_br => |x| blk: {
                var y = x;
                if (isVregByte(y.lhs, from)) y.lhs = to else if (isVregByte(y.rhs, from)) y.rhs = to else break :blk null;
                break :blk mcsmir.Op{ .cmp_br = y };
            },
            .br_ifnz => |x| if (isVregByte(x.cond, from)) mcsmir.Op{ .br_ifnz = .{ .cond = to, .target = x.target } } else null,
            .br_ifz => |x| if (isVregByte(x.cond, from)) mcsmir.Op{ .br_ifz = .{ .cond = to, .target = x.target } } else null,
            .push => |x| if (isVregByte(x.src, from)) mcsmir.Op{ .push = .{ .src = to } } else null,
            .store_dir => |x| if (isVregByte(x.src, from)) mcsmir.Op{ .store_dir = .{ .addr = x.addr, .src = to } } else null,
            .store_xdata => |x| if (isVregByte(x.src, from)) mcsmir.Op{ .store_xdata = .{ .addr = x.addr, .src = to } } else null,
            .load_xdata_idx => |x| if (isVregByte(x.idx, from)) mcsmir.Op{ .load_xdata_idx = .{ .dst = x.dst, .base = x.base, .idx = to, .scale = x.scale } } else null,
            .load_xdata_idx_sym => |x| if (isVregByte(x.idx, from)) mcsmir.Op{ .load_xdata_idx_sym = .{ .dst = x.dst, .sym = x.sym, .idx = to, .scale = x.scale } } else null,
            .load_code_idx_sym => |x| if (isVregByte(x.idx, from)) mcsmir.Op{ .load_code_idx_sym = .{ .dst = x.dst, .sym = x.sym, .off = x.off, .idx = to, .scale = x.scale } } else null,
            .store_xdata_idx_sym => |x| blk: {
                if (isVregByte(x.idx, from)) break :blk mcsmir.Op{ .store_xdata_idx_sym = .{ .sym = x.sym, .idx = to, .src = x.src, .scale = x.scale } };
                if (isVregByte(x.src, from)) break :blk mcsmir.Op{ .store_xdata_idx_sym = .{ .sym = x.sym, .idx = x.idx, .src = to, .scale = x.scale } };
                break :blk null;
            },
            .store_xdata_sym => |x| if (isVregByte(x.src, from)) mcsmir.Op{ .store_xdata_sym = .{ .sym = x.sym, .off = x.off, .src = to } } else null,
            .store_xdata_idx => |x| blk: {
                if (isVregByte(x.idx, from)) break :blk mcsmir.Op{ .store_xdata_idx = .{ .base = x.base, .idx = to, .src = x.src, .scale = x.scale } };
                if (isVregByte(x.src, from)) break :blk mcsmir.Op{ .store_xdata_idx = .{ .base = x.base, .idx = x.idx, .src = to, .scale = x.scale } };
                break :blk null;
            },
            else => null,
        };
    }

    /// 相邻拷贝折叠：`mov vd,vs` + 紧邻的唯一读 vd → 删掉 mov。
    fn foldCopies(self: *Lower) void {
        var i: usize = 0;
        while (i + 1 < self.ops.items.len) {
            const m = switch (self.ops.items[i]) {
                .mov => |x| x,
                else => {
                    i += 1;
                    continue;
                },
            };
            const d = switch (m.dst) {
                .vreg => |v| v,
                else => {
                    i += 1;
                    continue;
                },
            };
            const nxt = self.ops.items[i + 1];
            const boundary = switch (nxt) {
                .label, .br, .br_ifnz, .br_ifz, .cmp_br, .dec_br_nz, .ret, .reti, .halt => true,
                else => false,
            };
            if (boundary or !readsVreg(nxt, d) or readCountVreg(self.ops.items, d) != 1) {
                i += 1;
                continue;
            }
            // 源是 ABI/易失寄存器（DPL/DPH/ACC/B）时**不能**折叠：下一条指令可能先把
            // DPTR 写掉（`mov dptr,#sym`），之后才轮到读这个操作数 —— 那就读到新值了。
            // 典型翻车：`const tbl` 的 `tbl[i]`（下标就住在 DPL，而符号基址要先装 DPTR）。
            if (m.src == .dir and switch (m.src.dir) {
                0x82, 0x83, 0xE0, 0xF0 => true,
                else => false,
            }) {
                i += 1;
                continue;
            }
            const replaced = substReadVreg(nxt, d, m.src) orelse {
                i += 1;
                continue;
            };
            self.ops.items[i + 1] = replaced;
            var k = i;
            while (k + 1 < self.ops.items.len) : (k += 1) self.ops.items[k] = self.ops.items[k + 1];
            self.ops.items.len -= 1;
            if (i > 0) i -= 1;
        }
    }

    fn rotateDjnz(self: *Lower) codegen.Error!void {
        var i: usize = 0;
        while (i + 1 < self.ops.items.len) : (i += 1) {
            const ops = self.ops.items;
            const head = switch (ops[i]) {
                .label => |n| n,
                else => continue,
            };
            // 顶部测试：标签后允许一小段读操作数（如 load i），再遇到 cmp_br。
            var test_pos: ?usize = null;
            var k1: usize = i + 1;
            while (k1 < ops.len and k1 < i + 8) : (k1 += 1) {
                switch (ops[k1]) {
                    .cmp_br => {
                        test_pos = k1;
                        break;
                    },
                    .label, .br, .ret, .halt, .br_ifnz, .br_ifz, .dec_br_nz => break,
                    else => {},
                }
            }
            const tp = test_pos orelse continue;
            const cb = ops[tp].cmp_br;
            if (cb.cc != .eq) continue;

            const lhs_r = vregOf(cb.lhs);
            const rhs_r = vregOf(cb.rhs);
            const lhs_zero = switch (cb.lhs) {
                .imm => |v| v == 0,
                else => false,
            };
            const rhs_zero = switch (cb.rhs) {
                .imm => |v| v == 0,
                else => false,
            };
            var counter: ?u8 = null;
            if (rhs_zero) {
                if (lhs_r) |r| counter = r;
            } else if (lhs_zero) {
                if (rhs_r) |r| counter = r;
            } else if (lhs_r != null and self.isZeroAt(lhs_r.?, tp)) {
                if (rhs_r) |r| counter = r;
            } else if (rhs_r != null and self.isZeroAt(rhs_r.?, tp)) {
                if (lhs_r) |r| counter = r;
            }
            const c0 = counter orelse continue;
            // 测试用的操作数常是「刚载入的副本」（mov c0, s）——真正被递减的是 s。
            var c = c0;
            var pk: usize = i + 1;
            while (pk < tp) : (pk += 1) {
                switch (ops[pk]) {
                    .mov => |x| if (vregOf(x.dst) == @as(?u8, c)) {
                        if (vregOf(x.src)) |s| c = s;
                    },
                    else => {},
                }
            }

            // 回边：正文里最后一条「br L 紧跟 label」的 br（就是 repeat）
            var back_pos: ?usize = null;
            var kk: usize = i + 2;
            while (kk + 1 < ops.len) : (kk += 1) {
                switch (ops[kk]) {
                    .br => |t| if (t == head) {
                        switch (ops[kk + 1]) {
                            .label => back_pos = kk,
                            else => {},
                        }
                    },
                    else => {},
                }
            }
            const bp = back_pos orelse continue;
            const ep = bp + 1;

            // body 里必须恰好一处 imm 1 + sub(c,c,1)，且没有别的 c 引用
            var sub_pos: ?usize = null;
            var imm_pos: ?usize = null;
            var bad = false;
            var k2 = tp + 1;
            while (k2 < bp) : (k2 += 1) {
                const op = ops[k2];
                const is_sub = switch (op) {
                    .sub => |x| vregOf(x.dst) == @as(?u8, c) and vregOf(x.lhs) == @as(?u8, c) and switch (x.rhs) {
                        .vreg, .imm => true,
                        else => false,
                    },
                    else => false,
                };
                if (is_sub) {
                    if (sub_pos != null) {
                        bad = true;
                        break;
                    }
                    const x = op.sub;
                    // 形态 1：rhs 是立即数 1（P1.5 之后）
                    var one_ok = switch (x.rhs) {
                        .imm => |v| v == 1,
                        else => false,
                    };
                    var prev_imm: ?usize = null;
                    if (!one_ok) {
                        // 形态 2：rhs 是装了 1 的 vreg，其定义紧挨着
                        if (vregOf(x.rhs)) |rk| {
                            if (k2 > 0) {
                                switch (ops[k2 - 1]) {
                                    .imm => |y| if (vregOf(y.dst) == @as(?u8, rk) and y.value == 1) {
                                        one_ok = true;
                                        prev_imm = k2 - 1;
                                    },
                                    else => {},
                                }
                            }
                        }
                    }
                    if (!one_ok) {
                        bad = true;
                        break;
                    }
                    sub_pos = k2;
                    imm_pos = prev_imm;
                    continue;
                }
                if (refsVreg(op, c)) {
                    bad = true;
                    break;
                }
            }
            if (bad or sub_pos == null) continue;

            const sp = sub_pos.?;
            const ip = imm_pos; // .imm 形态没有独立 imm 指令

            // 组装新序列
            const body_lbl = self.tempLabel();
            var out: std.ArrayListUnmanaged(mcsmir.Op) = .empty;
            errdefer out.deinit(self.gpa);
            try out.appendSlice(self.gpa, ops[0 .. tp + 1]);
            try out.append(self.gpa, .{ .label = body_lbl });
            for (ops[tp + 1 .. bp], tp + 1..) |op, k| {
                if (k == sp) continue;
                if (ip) |ii| {
                    if (k == ii) continue;
                }
                try out.append(self.gpa, op);
            }
            try out.append(self.gpa, .{ .dec_br_nz = .{ .dst = .{ .vreg = c }, .target = body_lbl } });
            try out.appendSlice(self.gpa, ops[bp + 1 ..]);
            self.ops.deinit(self.gpa);
            self.ops = out;
            i = ep;
        }
    }

    // ==== 部分求值（切片 A）====
    //
    // 条件：无参数、无 SFR/xdata 读、无栈操作、步数有界、能走到 ret。
    // 做法：在 MIR 上直接解释执行，把最终写回（dir/xdata）物化成常量存储。
    // 这样「确定的操作」在编译期就算完，hex 里只剩结果。

    const FoldWrite = struct { addr: u16, val: u8, is_dir: bool };

    fn foldGet(b: mcsmir.Byte, regs: *const [256]u8, dirs: *const [256]u8) ?u8 {
        return switch (b) {
            .vreg => |r| regs[r],
            .dir => |d| dirs[d],
            .sym => null,
            .imm => |v| v,
        };
    }

    fn foldSet(b: mcsmir.Byte, val: u8, regs: *[256]u8, dirs: *[256]u8) bool {
        switch (b) {
            .vreg => |r| regs[r] = val,
            .dir => |d| dirs[d] = val,
            .sym => return false,
            .imm => return false,
        }
        return true;
    }

    fn foldCc(cc: mcsmir.Cc, l: u8, r: u8) bool {
        return switch (cc) {
            .lt => l < r,
            .le => l <= r,
            .gt => l > r,
            .ge => l >= r,
            .eq => l == r,
            .ne => l != r,
        };
    }

    fn foldPure(self: *Lower) codegen.Error!bool {
        const ops = self.ops.items;
        if (ops.len == 0) return false;
        for (ops) |op| switch (op) {
            // 硬件访问一律不折：SFR/xdata 的读写带时序与副作用，折了会丢时序。
            // 唯一例外是 DPL(0x82)——那是 u8 返回值的 ABI 出口，不是硬件副作用。
            .load_dir, .load_xdata, .store_xdata,
            .load_xdata_idx, .store_xdata_idx,
            .push, .pop, .reti, .halt => return false,
            .store_dir => |x| if (x.addr != 0x82) return false,
            else => {},
        };

        var regs: [256]u8 = undefined;
        var dirs: [256]u8 = undefined;
        var wrote_dir: [256]bool = undefined;
        @memset(&regs, 0);
        @memset(&dirs, 0);
        @memset(&wrote_dir, false);
        var xw: std.ArrayListUnmanaged(FoldWrite) = .empty;
        defer xw.deinit(self.gpa);

        var pc: usize = 0;
        var steps: usize = 0;
        var folded = false;

        while (pc < ops.len) {
            if (steps >= 200_000) return false;
            steps += 1;
            switch (ops[pc]) {
                .imm => |x| {
                    if (!foldSet(x.dst, x.value, &regs, &dirs)) return false;
                    pc += 1;
                },
                .mov => |x| {
                    const v = foldGet(x.src, &regs, &dirs) orelse return false;
                    if (!foldSet(x.dst, v, &regs, &dirs)) return false;
                    pc += 1;
                },
                .add => |x| {
                    const a = foldGet(x.lhs, &regs, &dirs) orelse return false;
                    const b = foldGet(x.rhs, &regs, &dirs) orelse return false;
                    if (!foldSet(x.dst, a +% b, &regs, &dirs)) return false;
                    pc += 1;
                },
                .sub => |x| {
                    const a = foldGet(x.lhs, &regs, &dirs) orelse return false;
                    const b = foldGet(x.rhs, &regs, &dirs) orelse return false;
                    if (!foldSet(x.dst, a -% b, &regs, &dirs)) return false;
                    pc += 1;
                },
                .dec => |r| {
                    regs[r] -%= 1;
                    pc += 1;
                },
                .and_ => |x| {
                    const a = foldGet(x.lhs, &regs, &dirs) orelse return false;
                    const b = foldGet(x.rhs, &regs, &dirs) orelse return false;
                    if (!foldSet(x.dst, a & b, &regs, &dirs)) return false;
                    pc += 1;
                },
                .or_ => |x| {
                    const a = foldGet(x.lhs, &regs, &dirs) orelse return false;
                    const b = foldGet(x.rhs, &regs, &dirs) orelse return false;
                    if (!foldSet(x.dst, a | b, &regs, &dirs)) return false;
                    pc += 1;
                },
                .xor_ => |x| {
                    const a = foldGet(x.lhs, &regs, &dirs) orelse return false;
                    const b = foldGet(x.rhs, &regs, &dirs) orelse return false;
                    if (!foldSet(x.dst, a ^ b, &regs, &dirs)) return false;
                    pc += 1;
                },
                .mul => |x| {
                    const a = foldGet(x.lhs, &regs, &dirs) orelse return false;
                    const b = foldGet(x.rhs, &regs, &dirs) orelse return false;
                    if (!foldSet(x.dst, a *% b, &regs, &dirs)) return false;
                    pc += 1;
                },
                .div_ => |x| {
                    const a = foldGet(x.lhs, &regs, &dirs) orelse return false;
                    const b = foldGet(x.rhs, &regs, &dirs) orelse return false;
                    if (b == 0) return false; // 除零不折（保持运行期行为）
                    if (!foldSet(x.dst, a / b, &regs, &dirs)) return false;
                    pc += 1;
                },
                .rem_ => |x| {
                    const a = foldGet(x.lhs, &regs, &dirs) orelse return false;
                    const b = foldGet(x.rhs, &regs, &dirs) orelse return false;
                    if (b == 0) return false;
                    if (!foldSet(x.dst, a % b, &regs, &dirs)) return false;
                    pc += 1;
                },
                .not_ => |x| {
                    const a = foldGet(x.src, &regs, &dirs) orelse return false;
                    if (!foldSet(x.dst, ~a, &regs, &dirs)) return false;
                    pc += 1;
                },
                .shl => |x| {
                    const a = foldGet(x.lhs, &regs, &dirs) orelse return false;
                    const v: u8 = if (x.n >= 8) 0 else a << @intCast(x.n);
                    if (!foldSet(x.dst, v, &regs, &dirs)) return false;
                    pc += 1;
                },
                .shr => |x| {
                    const a = foldGet(x.lhs, &regs, &dirs) orelse return false;
                    const v: u8 = if (x.n >= 8) 0 else a >> @intCast(x.n);
                    if (!foldSet(x.dst, v, &regs, &dirs)) return false;
                    pc += 1;
                },
                .store_dir => |x| {
                    const v = foldGet(x.src, &regs, &dirs) orelse return false;
                    dirs[x.addr] = v;
                    wrote_dir[x.addr] = true;
                    pc += 1;
                },
                .store_xdata => |x| {
                    const v = foldGet(x.src, &regs, &dirs) orelse return false;
                    // 后写覆盖前写
                    var replaced = false;
                    for (xw.items) |*e| {
                        if (!e.is_dir and e.addr == x.addr) {
                            e.val = v;
                            replaced = true;
                            break;
                        }
                    }
                    if (!replaced) try xw.append(self.gpa, .{ .addr = x.addr, .val = v, .is_dir = false });
                    pc += 1;
                },
                .label => pc += 1,
                .br => |t| {
                    pc = self.findLabel(t) orelse return false;
                },
                .br_ifnz => |x| {
                    const v = foldGet(x.cond, &regs, &dirs) orelse return false;
                    pc = if (v != 0) (self.findLabel(x.target) orelse return false) else pc + 1;
                },
                .br_ifz => |x| {
                    const v = foldGet(x.cond, &regs, &dirs) orelse return false;
                    pc = if (v == 0) (self.findLabel(x.target) orelse return false) else pc + 1;
                },
                .cmp_br => |x| {
                    const a = foldGet(x.lhs, &regs, &dirs) orelse return false;
                    const b = foldGet(x.rhs, &regs, &dirs) orelse return false;
                    pc = if (foldCc(x.cc, a, b)) (self.findLabel(x.target) orelse return false) else pc + 1;
                },
                .dec_br_nz => |x| {
                    const v = foldGet(x.dst, &regs, &dirs) orelse return false;
                    const nv = v -% 1;
                    if (!foldSet(x.dst, nv, &regs, &dirs)) return false;
                    pc = if (nv != 0) (self.findLabel(x.target) orelse return false) else pc + 1;
                },
                .ret => {
                    folded = true;
                    break;
                },
                else => return false,
            }
        }
        if (!folded) return false;

        // 用常量写回替换整个函数体：vreg 0 作为临时，nregs = 1。
        const new_ops: std.ArrayListUnmanaged(mcsmir.Op) = .empty;
        self.ops.deinit(self.gpa);
        self.ops = new_ops;
        self.nregs = 1;
        const tmp = mcsmir.v(0);
        for (xw.items) |e| {
            try self.ops.append(self.gpa, .{ .imm = .{ .dst = tmp, .value = e.val } });
            try self.ops.append(self.gpa, .{ .store_xdata = .{ .addr = e.addr, .src = tmp } });
        }
        var d: u16 = 0;
        while (d < 256) : (d += 1) {
            if (!wrote_dir[d]) continue;
            // PE.2：直接写直址（mov dir,#imm），不再经 vreg 中转。
            try self.ops.append(self.gpa, .{ .imm = .{ .dst = .{ .dir = @intCast(d) }, .value = dirs[d] } });
        }
        try self.ops.append(self.gpa, .{ .ret = {} });
        return true;
    }

    fn findLabel(self: *Lower, id: u32) ?usize {
        for (self.ops.items, 0..) |op, i| switch (op) {
            .label => |l| if (l == id) return i + 1,
            else => {},
        };
        return null;
    }

    fn emitCondBr(self: *Lower, inst: Air.Inst.Index) codegen.Error!void {
        const air = self.air;
        const cb = air.unwrapCondBr(inst);
        const else_lbl = self.tempLabel();
        const end_lbl = self.blockEnd(inst);

        // 编译期常量条件
        if (cb.condition.toInterned()) |ip_index| {
            const key = self.zcu.intern_pool.indexToKey(ip_index);
            if (key == .int) {
                const v = switch (key.int.storage) {
                    .u64 => |x| x,
                    else => 0,
                };
                if (v != 0) {
                    _ = try self.emitBody(cb.then_body);
                } else {
                    _ = try self.emitBody(cb.else_body);
                }
                return;
            }
        }

        var fused = false;
        if (cb.condition.toIndex()) |cond_idx| {
            const tg = air.instructions.items(.tag)[@backingInt(cond_idx)];
            if (ccOf(tg)) |cc| {
                const bin = air.instructions.items(.data)[@backingInt(cond_idx)].bin_op;
                const oty = air.typeOf(bin.lhs, &self.zcu.intern_pool);
                const info = self.intInfo(oty);
                if (info != null and (info.?.bytes > 1 or info.?.signed)) {
                    // 多字节/有符号比较：整条借位链一次发完（8 位无符号仍走 cmp_br）。
                    const oi = info.?;
                    const lhs = try self.wideOperand(bin.lhs, oi.bytes);
                    const rhs = try self.wideOperand(bin.rhs, oi.bytes);
                    const tmp = try self.allocVreg();
                    try self.ops.append(self.gpa, .{ .cmp_wide_br = .{
                        .lhs = lhs,
                        .rhs = rhs,
                        .n = oi.bytes,
                        .tmp = mcsmir.v(tmp),
                        .cc = cc.invert(),
                        .signed = oi.signed,
                        .target = else_lbl,
                    } });
                } else {
                    const lhs = try self.refLoc(bin.lhs);
                    const rhs = try self.refLoc(bin.rhs);
                    // 条件不成立 → else：取反。
                    try self.ops.append(self.gpa, .{ .cmp_br = .{
                        .lhs = lhs,
                        .rhs = rhs,
                        .cc = cc.invert(),
                        .target = else_lbl,
                    } });
                }
                fused = true;
            }
        }
        if (!fused) {
            const c = try self.refLoc(cb.condition);
            try self.ops.append(self.gpa, .{ .br_ifz = .{ .cond = c, .target = else_lbl } });
        }

        const then_term = try self.emitBody(cb.then_body);
        if (!then_term) try self.ops.append(self.gpa, .{ .br = end_lbl });
        try self.ops.append(self.gpa, .{ .label = else_lbl });
        _ = try self.emitBody(cb.else_body);
        try self.ops.append(self.gpa, .{ .label = end_lbl });
    }

    fn emitBody(self: *Lower, body: []const Air.Inst.Index) codegen.Error!bool {
    var skip_idx: ?usize = null;
    for (body, 0..) |inst, idx| {
        if (skip_idx) |s| {
            if (s == idx) {
                skip_idx = null;
                continue;
            }
        }
        // 每条 AIR 指令结束时把「临时操作数槽」还回池里（结果槽不还）。
        // `continue` / `return` 都会跑到这个 defer，所以各分支不用各自记得清。
        defer self.flushTempsKeep(self.resultSlot(inst));
        const tag = self.air.instructions.items(.tag)[@backingInt(inst)];
        const data = self.air.instructions.items(.data)[@backingInt(inst)];
        // 函数名以 _airdump 结尾时，把 AIR 指令序列打到 stderr（tag + 关键操作数）。
        // 改 codegen 前先看这个，比反复加调试打印快得多。
        if (self.dump_air) {
            // 只打 tag（不解析载荷）：载荷布局随 tag 不同，硬解析会越界（踩过 panic）。
            std.debug.print("AIR[{d}] {s}\n", .{ @backingInt(inst), @tagName(tag) });
        }
        switch (tag) {
            .dbg_stmt, .dbg_empty_stmt, .dbg_inline_block, .dbg_var_ptr, .dbg_var_val, .dbg_arg_inline => {},

            .arg => {
                const ty = self.air.typeOfIndex(inst, &self.zcu.intern_pool);
                if (self.wideBytes(ty) == null and ty.zigTypeTag(self.zcu) != .bool) {
                    return self.zcu.codegenFail(
                        self.nav,
                        "mcs2: 参数类型 {s} 尚未实现（目前只支持 8/16/32 位整数与 bool）",
                        .{@tagName(ty.zigTypeTag(self.zcu))},
                    );
                }
                // SDCC mcs51 实测约定（--model-small）：**第 1 个参数**按低字节序进
                // DPL/DPH/B/A（最多 4 字节），**第 2 个起**进 `_名_PARM_2` 起的连续字节。
                // 对齐它 = u16/u32 的 C 互操作免费，不需要 thunk。
                // ADR-001 边界 ABI：按**字节**摆放（arg0 → DPL，之后 → PARM_n）；
                // u16 占两个字节（DPL/DPH 或 PARM_n/PARM_{n+1}）。
                const nlat = self.wideBytes(ty) orelse 1;
                if (nlat > 1) {
                    const base = try self.allocWide(nlat);
                    var k: u8 = 0;
                    while (k < nlat) : (k += 1) {
                        const src: mcsmir.Byte = if (self.arg_cursor == 0)
                            .{ .dir = mcsmir.abi.arg_regs[k] }
                        else blk: {
                            const psym = try std.fmt.allocPrint(self.gpa, "_{s}_PARM_{d}", .{ self.short_name, self.spill_off + k });
                            try self.parms.append(self.gpa, psym);
                            break :blk .{ .sym = psym };
                        };
                        try self.ops.append(self.gpa, .{ .mov = .{ .dst = mcsmir.v(base + k), .src = src } });
                    }
                    if (self.arg_cursor == 0) {
                        if (nlat >= 3) self.b_is_arg = true; // B 是第 3 个字节
                    } else {
                        self.spill_off += nlat;
                    }
                    self.arg_cursor += 1;
                    self.vals[@backingInt(inst)] = mcsmir.v(base);
                    self.wide[@backingInt(inst)] = @as(u16, base) | (@as(u16, nlat) << 8);
                    continue;
                }
                if (self.arg_cursor == 0) {
                    if (self.needs_dptr) {
                        // DPL 会被地址计算覆盖：先落到 vreg（3 字节，换正确性）。
                        const r0 = try self.allocVreg();
                        try self.ops.append(self.gpa, .{ .mov = .{
                            .dst = mcsmir.v(r0),
                            .src = .{ .dir = mcsmir.abi.arg_regs[0] },
                        } });
                        self.vals[@backingInt(inst)] = mcsmir.v(r0);
                    } else {
                        self.vals[@backingInt(inst)] = .{ .dir = mcsmir.abi.arg_regs[0] };
                    }
                } else {
                    const psym = try std.fmt.allocPrint(
                        self.gpa,
                        "_{s}_PARM_{d}",
                        .{ self.short_name, self.spill_off },
                    );
                    try self.parms.append(self.gpa, psym);
                    self.spill_off += 1;
                    self.vals[@backingInt(inst)] = .{ .sym = psym };
                }
                self.arg_cursor += 1;
            },

            .ptr_elem_ptr => {
                // 基址：固定地址（@ptrFromInt）或全局/静态变量的符号地址；
                // 元素地址 = 基址 + idx*scale，常量下标直接折进地址。
                const bin = self.air.extraData(Air.Bin, @intCast(data.ty_pl.payload)).data;
                const pr = self.ptrRefOf(bin.lhs) orelse
                    return self.fail("指针下标的基址必须是固定地址或全局变量（暂不支持运行期指针）", .{});
                {
                    // 元素字节数 = 结果指针的子类型宽度（u8=1 / u16=2 / u32=4）
                    const pty = self.air.typeOfIndex(inst, &self.zcu.intern_pool);
                    // 指针子类型可能是**数组**（T16[i] 的 lhs 是 *[8]u16）→ 再取元素类型
                    var ety = pty.childType(self.zcu);
                    while (ety.zigTypeTag(self.zcu) == .array) ety = ety.childType(self.zcu);
                    const sc = try self.storageBytes(ety, "下标元素");
                    if (self.dump_air) std.debug.print("  >> elem scale={d} res={s} ety={s}\n", .{
                        sc,
                        @tagName(pty.zigTypeTag(self.zcu)),
                        @tagName(ety.zigTypeTag(self.zcu)),
                    });
                    switch (pr) {
                        .fixed => |base| {
                            if (self.constU8(bin.rhs)) |k| {
                                self.ptr_vals[@backingInt(inst)] = .{ .fixed = base + @as(u64, k) * sc };
                                continue;
                            }
                            const idx_loc = try self.refLoc(bin.rhs);
                            self.ptr_vals[@backingInt(inst)] = .{ .elem = .{ .base = base, .idx = idx_loc, .scale = sc } };
                        },
                        .sym_off => |s| {
                            if (self.constU8(bin.rhs)) |k| {
                                self.ptr_vals[@backingInt(inst)] = .{ .sym_off = .{ .sym = s.sym, .off = s.off + @as(u64, k) * sc } };
                                continue;
                            }
                            const idx_loc = try self.refLoc(bin.rhs);
                            self.ptr_vals[@backingInt(inst)] = .{ .elem_sym = .{ .sym = s.sym, .off = s.off, .idx = idx_loc, .scale = sc } };
                        },
                        // const 表（代码段）：常量下标折成 _sym+off，运行期下标走 movc 链
                        .code_sym => |s| {
                            if (self.constU8(bin.rhs)) |k| {
                                self.ptr_vals[@backingInt(inst)] = .{ .code_sym = .{ .sym = s.sym, .off = s.off + @as(u64, k) * sc } };
                                continue;
                            }
                            const idx_loc = try self.refLoc(bin.rhs);
                            self.ptr_vals[@backingInt(inst)] = .{ .code_elem_sym = .{ .sym = s.sym, .off = s.off, .idx = idx_loc, .scale = sc } };
                        },
                        .elem, .elem_sym, .code_elem_sym => return self.fail("多级下标（链式指针运算）暂不支持", .{}),
                    }
                }
            },

            .add, .add_safe, .add_wrap, .sub, .sub_safe, .sub_wrap => {
                const bin = data.bin_op;
                const ty = self.air.typeOfIndex(inst, &self.zcu.intern_pool);
                const n = (try self.requireIntWidth(ty, "加减法")).bytes;
                // 多字节：固定模板 = clr c + addc/subb 逐字节（低字节在前）。
                if (n > 1) {
                    const a = try self.wideOperand(bin.lhs, n);
                    const b = try self.wideOperand(bin.rhs, n);
                    const d = try self.allocWide(n);
                    const is_add = switch (tag) {
                        .add, .add_safe, .add_wrap => true,
                        else => false,
                    };
                    try self.ops.append(self.gpa, .{ .clr_c = {} });
                    var k: u8 = 0;
                    while (k < n) : (k += 1) {
                        try self.ops.append(self.gpa, if (is_add)
                            .{ .addc = .{ .dst = mcsmir.v(d + k), .lhs = mcsmir.v(a + k), .rhs = mcsmir.v(b + k) } }
                        else .{ .subb = .{ .dst = mcsmir.v(d + k), .lhs = mcsmir.v(a + k), .rhs = mcsmir.v(b + k) } });
                    }
                    self.vals[@backingInt(inst)] = mcsmir.v(d);
                    self.wide[@backingInt(inst)] = @as(u16, d) | (@as(u16, n) << 8);
                    continue;
                }
                const lhs = try self.refLoc(bin.lhs);
                const rhs = try self.refLoc(bin.rhs);
                // 「ret 前看一眼」：下一非调试指令若是 ret 且操作数是本指令，
                // 结果直接写 DPL（扩展访问优化的最小版：省一次 vreg 往返）。
                var consumed_by_ret = false;
                if (self.ret_byte != null and idx + 1 < body.len) {
                    const nxt = body[idx + 1];
                    const nxt_tag = self.air.instructions.items(.tag)[@backingInt(nxt)];
                    if (nxt_tag == .ret or nxt_tag == .ret_safe) {
                        const nxt_data = self.air.instructions.items(.data)[@backingInt(nxt)];
                        if (nxt_data.un_op.toIndex()) |ret_operand| {
                            if (@backingInt(ret_operand) == @backingInt(inst)) {
                                consumed_by_ret = true;
                            }
                        }
                    }
                }
                var dst: Loc = if (consumed_by_ret)
                    .{ .dir = self.ret_byte.? }
                else
                    mcsmir.v(try self.allocVreg());

                // P1：结果紧接着写回某个本地槽 → 直接写那个槽，store 整条省掉。
                if (!consumed_by_ret) {
                    if (self.nextRealIdx(body, idx)) |nxt| {
                        const ntag = self.air.instructions.items(.tag)[@backingInt(body[nxt])];
                        if (ntag == .store or ntag == .store_safe) {
                            const nd = self.air.instructions.items(.data)[@backingInt(body[nxt])].bin_op;
                            const rhs_is_me = if (nd.rhs.toIndex()) |x| @backingInt(x) == @backingInt(inst) else false;
                            if (rhs_is_me and self.constPtrAddr(nd.lhs) == null) {
                                if (nd.lhs.toIndex()) |pi| {
                                    if (self.vals[@backingInt(pi)]) |slot| {
                                        dst = slot;
                                        skip_idx = nxt;
                                    }
                                }
                            }
                        }
                    }
                }
                const is_add = switch (tag) {
                    .add, .add_safe, .add_wrap => true,
                    else => false,
                };
                try self.ops.append(self.gpa, if (is_add)
                    .{ .add = .{ .dst = dst, .lhs = lhs, .rhs = rhs } }
                else
                    .{ .sub = .{ .dst = dst, .lhs = lhs, .rhs = rhs } });
                self.vals[@backingInt(inst)] = dst;
            },

            // 位运算：按位与/或/异或都是逐字节的，多字节只是把模板重复 n 次
            // （不进位、不借位，和宽度无关）。
            .bit_and, .bit_or, .xor => {
                const ty = self.air.typeOfIndex(inst, &self.zcu.intern_pool);
                const n = (try self.requireIntWidth(ty, "位运算")).bytes;
                const bin = data.bin_op;
                if (n > 1) {
                    const a = try self.wideOperand(bin.lhs, n);
                    const b = try self.wideOperand(bin.rhs, n);
                    const d = try self.allocWide(n);
                    var k: u8 = 0;
                    while (k < n) : (k += 1) {
                        try self.ops.append(self.gpa, switch (tag) {
                            .bit_and => .{ .and_ = .{ .dst = mcsmir.v(d + k), .lhs = mcsmir.v(a + k), .rhs = mcsmir.v(b + k) } },
                            .bit_or => .{ .or_ = .{ .dst = mcsmir.v(d + k), .lhs = mcsmir.v(a + k), .rhs = mcsmir.v(b + k) } },
                            else => .{ .xor_ = .{ .dst = mcsmir.v(d + k), .lhs = mcsmir.v(a + k), .rhs = mcsmir.v(b + k) } },
                        });
                    }
                    self.vals[@backingInt(inst)] = mcsmir.v(d);
                    self.wide[@backingInt(inst)] = @as(u16, d) | (@as(u16, n) << 8);
                    continue;
                }
                const lhs = try self.refLoc(bin.lhs);
                const rhs = try self.refLoc(bin.rhs);
                const d = mcsmir.v(try self.allocVreg());
                try self.ops.append(self.gpa, switch (tag) {
                    .bit_and => .{ .and_ = .{ .dst = d, .lhs = lhs, .rhs = rhs } },
                    .bit_or => .{ .or_ = .{ .dst = d, .lhs = lhs, .rhs = rhs } },
                    else => .{ .xor_ = .{ .dst = d, .lhs = lhs, .rhs = rhs } },
                });
                self.vals[@backingInt(inst)] = d;
            },

            // 乘/除/取余/取反（u8）。8051 用 MUL AB / DIV AB，B 是结果高字节或余数，
            // 而 B(0xF0) 同时是 arg2 的 ABI 位置 —— 用到了就保存/恢复。
            .mul, .mul_wrap, .div_trunc, .rem, .not => {
                const ty = self.air.typeOfIndex(inst, &self.zcu.intern_pool);
                const info = try self.requireIntWidth(ty, "乘除/取反");
                if (tag == .not) {
                    if (info.bytes > 1) {
                        const s = try self.wideOperand(data.ty_op.operand, info.bytes);
                        const d = try self.allocWide(info.bytes);
                        var k: u8 = 0;
                        while (k < info.bytes) : (k += 1) {
                            try self.ops.append(self.gpa, .{ .not_ = .{ .dst = mcsmir.v(d + k), .src = mcsmir.v(s + k) } });
                        }
                        self.vals[@backingInt(inst)] = mcsmir.v(d);
                        self.wide[@backingInt(inst)] = @as(u16, d) | (@as(u16, info.bytes) << 8);
                        continue;
                    }
                    const d = mcsmir.v(try self.allocVreg());
                    const src = try self.refLoc(data.ty_op.operand);
                    try self.ops.append(self.gpa, .{ .not_ = .{ .dst = d, .src = src } });
                    self.vals[@backingInt(inst)] = d;
                    continue;
                }
                // 多字节，或 8 位有符号（DIV AB/MUL AB 都是无符号 8 位）→ 固定模板。
                if (info.bytes > 1 or info.signed) {
                    const n = info.bytes;
                    const binw = data.bin_op;
                    const a = try self.wideOperand(binw.lhs, n);
                    const b2 = try self.wideOperand(binw.rhs, n);
                    var saved_bw: ?u8 = null;
                    if (self.b_is_arg) {
                        saved_bw = try self.allocVreg();
                        try self.ops.append(self.gpa, .{ .mov = .{ .dst = mcsmir.v(saved_bw.?), .src = .{ .dir = 0xF0 } } });
                    }
                    const dw = blk2: {
                        if (tag == .mul or tag == .mul_wrap) {
                            const t = try self.allocWide(n);
                            try self.mulWide(t, a, b2, n);
                            break :blk2 t;
                        }
                        break :blk2 try self.divmodWide(a, b2, n, info.signed, tag == .div_trunc);
                    };
                    if (saved_bw) |sv| {
                        try self.ops.append(self.gpa, .{ .mov = .{ .dst = .{ .dir = 0xF0 }, .src = mcsmir.v(sv) } });
                    }
                    self.vals[@backingInt(inst)] = mcsmir.v(dw);
                    self.wide[@backingInt(inst)] = @as(u16, dw) | (@as(u16, n) << 8);
                    continue;
                }
                const d = mcsmir.v(try self.allocVreg());
                const bin = data.bin_op;
                const lhs = try self.refLoc(bin.lhs);
                const rhs = try self.refLoc(bin.rhs);
                // B 被用作 arg2 → 先存起来，算完再放回。
                var saved_b: ?u8 = null;
                if (self.b_is_arg) {
                    saved_b = try self.allocVreg();
                    try self.ops.append(self.gpa, .{ .mov = .{ .dst = mcsmir.v(saved_b.?), .src = .{ .dir = 0xF0 } } });
                }
                try self.ops.append(self.gpa, switch (tag) {
                    .div_trunc => .{ .div_ = .{ .dst = d, .lhs = lhs, .rhs = rhs } },
                    .rem => .{ .rem_ = .{ .dst = d, .lhs = lhs, .rhs = rhs } },
                    else => .{ .mul = .{ .dst = d, .lhs = lhs, .rhs = rhs } },
                });
                if (saved_b) |sv| {
                    try self.ops.append(self.gpa, .{ .mov = .{ .dst = .{ .dir = 0xF0 }, .src = mcsmir.v(sv) } });
                }
                self.vals[@backingInt(inst)] = d;
            },

            // 移位：8 位无符号用 rlc/rrc 逐位；多字节与有符号右移走固定模板。
            //
            // 有符号右移是唯一的例外：rrc 链会补 0，必须**在移位前**取符号位
            // （sex 得到 0x00/0xFF），移完再把最高 cnt 位或成符号——
            // 整字节直接覆盖，余下 cnt%8 位按掩码 or 进去。
            .shl, .shl_exact, .shr, .shr_exact => {
                const ty = self.air.typeOfIndex(inst, &self.zcu.intern_pool);
                const info = try self.requireIntWidth(ty, "移位");
                const bin = data.bin_op;
                const left = switch (tag) { .shl, .shl_exact => true, else => false };
                // 运行期移位次数：按「每轮 1 位」循环（次数 0 直接跳过），
                // 8 位也走同一条模板——省一套专用发射路径。
                const cnt = self.constU8(bin.rhs) orelse {
                    const nw = info.bytes;
                    const a_rt = try self.wideOperand(bin.lhs, nw);
                    const d_rt = try self.allocWide(nw);
                    const cloc = try self.refLoc(bin.rhs);
                    try self.shiftRuntime(d_rt, a_rt, nw, cloc, left, !left and info.signed);
                    self.vals[@backingInt(inst)] = mcsmir.v(d_rt);
                    self.wide[@backingInt(inst)] = @as(u16, d_rt) | (@as(u16, nw) << 8);
                    continue;
                };
                if (info.bytes == 1 and (left or !info.signed)) {
                    const lhs = try self.refLoc(bin.lhs);
                    const d = mcsmir.v(try self.allocVreg());
                    try self.ops.append(self.gpa, switch (tag) {
                        .shl, .shl_exact => .{ .shl = .{ .dst = d, .lhs = lhs, .n = cnt } },
                        else => .{ .shr = .{ .dst = d, .lhs = lhs, .n = cnt } },
                    });
                    self.vals[@backingInt(inst)] = d;
                    continue;
                }
                const nw = info.bytes;
                const a = try self.wideOperand(bin.lhs, nw);
                const d = try self.allocWide(nw);
                var sign_ext: ?u8 = null;
                if (!left and info.signed) {
                    const e = try self.allocVreg();
                    try self.ops.append(self.gpa, .{ .sex = .{ .dst = mcsmir.v(e), .src = mcsmir.v(a + (nw - 1)) } });
                    sign_ext = e;
                }
                // 先复制到目标（允许原地）；左移从低字节到高字节，右移反过来。
                var c0: u8 = 0;
                while (c0 < nw) : (c0 += 1) try self.movTo(d + c0, mcsmir.v(a + c0));
                var step: u8 = 0;
                while (step < cnt) : (step += 1) {
                    try self.ops.append(self.gpa, .{ .clr_c = {} });
                    var k: u8 = 0;
                    while (k < nw) : (k += 1) {
                        const bidx = if (left) k else (nw - 1 - k);
                        try self.ops.append(self.gpa, if (left)
                            .{ .rlc = .{ .dst = mcsmir.v(d + bidx), .src = mcsmir.v(d + bidx) } }
                        else .{ .rrc = .{ .dst = mcsmir.v(d + bidx), .src = mcsmir.v(d + bidx) } });
                    }
                }
                if (sign_ext) |e| {
                    const full = cnt / 8;
                    const rem = cnt % 8;
                    var i: u8 = 0;
                    while (i < full and i < nw) : (i += 1) try self.movTo(d + (nw - 1 - i), mcsmir.v(e));
                    if (rem != 0 and full < nw) {
                        const mask: u8 = @truncate(@as(u16, 0xFF) << @intCast(8 - rem));
                        const t2 = try self.allocVreg();
                        try self.ops.append(self.gpa, .{ .and_ = .{
                            .dst = mcsmir.v(t2),
                            .lhs = mcsmir.v(e),
                            .rhs = .{ .imm = mask },
                        } });
                        const tgt = mcsmir.v(d + (nw - 1 - full));
                        try self.ops.append(self.gpa, .{ .or_ = .{ .dst = tgt, .lhs = tgt, .rhs = mcsmir.v(t2) } });
                    }
                }
                self.vals[@backingInt(inst)] = mcsmir.v(d);
                self.wide[@backingInt(inst)] = @as(u16, d) | (@as(u16, nw) << 8);
            },

            // 整数转换：≤16 位一律透传（本后端只跟踪 8 位值；下标被当作 u8 使用）。
            // 目的：让 `buf[i]`（i: u8 → usize 下标）不再被拒绝。
            // bit_cast 也走这条：同宽整数是纯透传；`@intFromBool`（bool→u8）是
            // 1 位零扩展（源是 bool，不是有符号整数，所以不会误做符号扩展）。
            // int_to_ptr / ptr_to_int 也走这条：把「地址装在 u16 里」的宽度信息带过去，
            // 间接调用要靠它拿到 2 字节目标地址。
            .int_cast, .int_cast_safe, .trunc, .bit_cast => {
                const ty_op = data.ty_op;
                const src_ty = self.air.typeOf(ty_op.operand, &self.zcu.intern_pool);
                const dst_ty = self.air.typeOfIndex(inst, &self.zcu.intern_pool);
                // 只跟踪 8 位：放宽（源 ≤8 位）与截断（目标 ≤8 位）都不改低字节，
                // 可以原样透传；两侧都更宽时语义不可丢失，直接拒绝。
                // 转换是「通道」：宽度未知的整数（如 usize 24 位、u64）按 1 字节透传，
                // 真正的安全闸门在算术/局部量/写回处——那里会明确拒绝奇异宽度。
                // 目标位宽「未知」（如 usize 在本目标是 24 位）：值不变，
                // 但**宽度信息必须按来源保留**——否则 u16 地址转 usize 再转指针就丢了高字节。
                const dst_w = self.wideBytes(dst_ty);
                const src_w = self.wideBytes(src_ty);
                if (dst_w == null and src_w != null) {
                    const base = try self.wideOperand(ty_op.operand, src_w.?);
                    self.vals[@backingInt(inst)] = mcsmir.v(base);
                    self.wide[@backingInt(inst)] = @as(u16, base) | (@as(u16, src_w.?) << 8);
                    continue;
                }
                const dn = dst_w orelse 1;
                const sn = src_w orelse 1;
                if (dn == 1 and sn == 1) {
                    self.vals[@backingInt(inst)] = try self.refLoc(ty_op.operand);
                } else if (dn == 1) {
                    // 收窄到 8 位：取低字节
                    const base = try self.wideOperand(ty_op.operand, sn);
                    self.vals[@backingInt(inst)] = mcsmir.v(base);
                } else {
                    // 放大或等宽：准备 dn 个槽位（高位补零）
                    const base = try self.wideOperand(ty_op.operand, dn);
                    self.vals[@backingInt(inst)] = mcsmir.v(base);
                    self.wide[@backingInt(inst)] = @as(u16, base) | (@as(u16, dn) << 8);
                }
            },

            // 取函数地址当值（`@intFromPtr(&f)`）：函数指针表的「填表」动作。
            // 地址就是 `_<fqn>` 这个 16 位符号，用 `mov dptr,#_sym` 装进 DPTR 再抄出来。
            .int_from_ptr => {
                const ty_op = data.ty_op;
                const sym = self.fnNavSym(ty_op.operand) orelse
                    return self.fail("只支持把**函数**地址转成整数（数据指针的地址暂不支持）", .{});
                const w = try self.allocWide(2);
                try self.ops.append(self.gpa, .{ .lea_dptr_sym = .{ .sym = sym } });
                try self.ops.append(self.gpa, .{ .mov = .{ .dst = mcsmir.v(w), .src = .{ .dir = 0x82 } } });
                try self.ops.append(self.gpa, .{ .mov = .{ .dst = mcsmir.v(w + 1), .src = .{ .dir = 0x83 } } });
                self.vals[@backingInt(inst)] = mcsmir.v(w);
                self.wide[@backingInt(inst)] = @as(u16, w) | (@as(u16, 2) << 8);
            },

            // 地址装进整数再转指针（@ptrFromInt）：位模式不变，只把宽度信息带过去，
            // 间接调用靠它拿到 2 字节目标地址。
            .ptr_from_int => {
                const ty_op = data.ty_op;
                const src_ty = self.air.typeOf(ty_op.operand, &self.zcu.intern_pool);
                // 源可能是 usize（这个目标里 24 位）→ 只取低 2 字节当地址。
                if (src_ty.zigTypeTag(self.zcu) != .int or src_ty.bitSize(self.zcu) < 16)
                    return self.fail("指针必须来自 ≥16 位整数（51 上地址是 2 字节）", .{});
                const base = try self.wideOperand(ty_op.operand, 2);
                self.vals[@backingInt(inst)] = mcsmir.v(base);
                self.wide[@backingInt(inst)] = @as(u16, base) | (@as(u16, 2) << 8);
            },

            .alloc => {
                // M1：每个局部槽一个 vreg（DSEG 直址）；活跃期优化留给后续 pass。
                // **注意 `.alloc` 的指令类型是指针**（`*T`），要取子类型才算得对宽度——
                // 以前直接把指针类型喂给 storageBytes，非 int 一律返回 1，于是 `var x: u16`
                // 只分到 1 个槽，之后 2 字节的 store 把**下一个局部量**的槽踩掉。
                const ty_raw = self.air.typeOfIndex(inst, &self.zcu.intern_pool);
                const ty = if (ty_raw.zigTypeTag(self.zcu) == .pointer) ty_raw.childType(self.zcu) else ty_raw;
                const n = try self.storageBytes(ty, "局部量");
                const base = try self.allocWide(n);
                self.vals[@backingInt(inst)] = mcsmir.v(base);
                if (n > 1) self.wide[@backingInt(inst)] = @as(u16, base) | (@as(u16, n) << 8);
            },

            .store, .store_safe => {
                // bin_op：lhs = 目标，rhs = 值。目标是指针就走 emitStoreByte（四种基址形态），
                // 否则是局部槽：多字节逐字节搬运（槽必须连续）。
                const rty = self.air.typeOf(data.bin_op.rhs, &self.zcu.intern_pool);
                const rn = try self.storageBytes(rty, "写回");
                const bin = data.bin_op;
                if (rn > 1) {
                    const sbase = try self.wideOperand(bin.rhs, rn);
                    if (self.ptrRefOf(bin.lhs)) |pr| {
                        var k: u8 = 0;
                        while (k < rn) : (k += 1) try self.emitStoreByte(pr, k, mcsmir.v(sbase + k));
                        continue;
                    }
                    const dest = try self.refLoc(bin.lhs);
                    const dbase: u8 = switch (dest) {
                        .vreg => |v| v,
                        else => return self.fail("多字节写目前只支持局部槽目标", .{}),
                    };
                    var k2: u8 = 0;
                    while (k2 < rn) : (k2 += 1) {
                        try self.ops.append(self.gpa, .{ .mov = .{ .dst = mcsmir.v(dbase + k2), .src = mcsmir.v(sbase + k2) } });
                    }
                    continue;
                }
                // 单字节：值若是多字节槽（截断写）→ 目标必须是局部槽。
                if (self.wideOf(bin.rhs)) |w| {
                    const wn: u8 = @truncate(w >> 8);
                    const sbase: u8 = @truncate(w & 0xFF);
                    const dest = try self.refLoc(bin.lhs);
                    const dbase = switch (dest) {
                        .vreg => |v| v,
                        else => return self.fail("多字节写目前只支持局部槽目标", .{}),
                    };
                    var k2: u8 = 0;
                    while (k2 < wn) : (k2 += 1) {
                        try self.ops.append(self.gpa, .{ .mov = .{ .dst = mcsmir.v(dbase + k2), .src = mcsmir.v(sbase + k2) } });
                    }
                    continue;
                }
                if (self.ptrRefOf(bin.lhs)) |pr| {
                    const value = try self.refLoc(bin.rhs);
                    try self.emitStoreByte(pr, 0, value);
                    continue;
                }
                const dest = try self.refLoc(bin.lhs);
                const value = try self.refLoc(bin.rhs);
                try self.ops.append(self.gpa, .{ .mov = .{ .dst = dest, .src = value } });
                // store 本身无结果值
            },

            // `buf[i]` 的两种折法：
            //   * `ptr_elem_val`：基址是**指针**（`*[N]T` / `[*]T`）；
            //   * `array_elem_val`：基址是**数组值**（`const tbl = .{…}` 这种 comptime 数组）。
            // 两者都降成「基址 + i*元素宽」的一次读取，共用下面的代码。
            .ptr_elem_val, .array_elem_val => {
                // 元素字节数 = 指令类型宽度（结果就是元素值），四种基址形态都走 emitLoadByte。
                const bin = data.bin_op;
                const ety = self.air.typeOfIndex(inst, &self.zcu.intern_pool);
                const n = try self.storageBytes(ety, "下标元素");
                const pr: PtrRef = self.ptrRefOf(bin.lhs) orelse blk: {
                    // 操作数是 comptime 聚合值（`const tbl = .{…}` + 运行期下标）：
                    // 把字节发进代码段，给个符号当只读表用。
                    if (bin.lhs.toInterned()) |ii| {
                        const lhs_ty = self.air.typeOf(bin.lhs, &self.zcu.intern_pool);
                        if (self.zcu.intern_pool.indexToKey(ii) == .aggregate) {
                            const sym = try self.internConstAggregate(ii, lhs_ty);
                            break :blk .{ .code_sym = .{ .sym = sym, .off = 0 } };
                        }
                    }
                    return self.fail("元素读取的基址必须是固定地址/全局变量/comptime 常量数组（暂不支持运行期指针）", .{});
                };
                // 常量下标：折成「基址 + k*scale」的一次访问
                if (self.constU8(bin.rhs)) |k| {
                    const folded: ?PtrRef = switch (pr) {
                        .fixed => |b| .{ .fixed = b + @as(u64, k) * n },
                        .sym_off => |s| .{ .sym_off = .{ .sym = s.sym, .off = s.off + @as(u64, k) * n } },
                        .code_sym => |s| .{ .code_sym = .{ .sym = s.sym, .off = s.off + @as(u64, k) * n } },
                        else => null,
                    };
                    if (folded) |folded_pr| {
                        const fb: u8 = if (n > 1) try self.allocWide(n) else try self.allocVreg();
                        var kk: u8 = 0;
                        while (kk < n) : (kk += 1) try self.emitLoadByte(folded_pr, kk, fb + kk);
                        self.vals[@backingInt(inst)] = mcsmir.v(fb);
                        if (n > 1) self.wide[@backingInt(inst)] = @as(u16, fb) | (@as(u16, n) << 8);
                        continue;
                    }
                }
                const idx_loc = try self.refLoc(bin.rhs);
                const indexed: PtrRef = switch (pr) {
                    .fixed => |b| blk: {
                        if (b <= 0xFF) return self.fail("直址（≤0xFF）暂不支持运行期下标：需要 @r0/@r1 间接寻址", .{});
                        if (b > 0xFFFF) return self.fail("下标基址 0x{X} 超出 51 可寻址范围", .{b});
                        break :blk .{ .elem = .{ .base = b, .idx = idx_loc, .scale = n } };
                    },
                    .sym_off => |s| .{ .elem_sym = .{ .sym = s.sym, .off = s.off, .idx = idx_loc, .scale = n } },
                    .code_sym => |s| .{ .code_elem_sym = .{ .sym = s.sym, .off = s.off, .idx = idx_loc, .scale = n } },
                    .elem, .elem_sym, .code_elem_sym => return self.fail("多级下标（链式指针运算）暂不支持", .{}),
                };
                const r: u8 = if (n > 1) try self.allocWide(n) else try self.allocVreg();
                var k3: u8 = 0;
                while (k3 < n) : (k3 += 1) try self.emitLoadByte(indexed, k3, r + k3);
                self.vals[@backingInt(inst)] = mcsmir.v(r);
                if (n > 1) self.wide[@backingInt(inst)] = @as(u16, r) | (@as(u16, n) << 8);
            },

            .load => {
                // 指针读取：逐字节发 `emitLoadByte`（四种基址形态统一走它）。
                // 宽类型（u16/u32）直接拼成 n 字节连续槽并记录宽信息。
                const lty = self.air.typeOfIndex(inst, &self.zcu.intern_pool);
                const ln_b = try self.storageBytes(lty, "读取");
                const ty_op = data.ty_op;
                if (self.ptrRefOf(ty_op.operand)) |pr| {
                    const wb: u8 = if (ln_b > 1) try self.allocWide(ln_b) else try self.allocVreg();
                    var k: u8 = 0;
                    while (k < ln_b) : (k += 1) try self.emitLoadByte(pr, k, wb + k);
                    self.vals[@backingInt(inst)] = mcsmir.v(wb);
                    if (ln_b > 1) self.wide[@backingInt(inst)] = @as(u16, wb) | (@as(u16, ln_b) << 8);
                    continue;
                }
                if (ln_b > 1) {
                    // 源是局部槽：槽位直接当多字节值。
                    const src = try self.refLoc(data.ty_op.operand);
                    const base: u8 = switch (src) {
                        .vreg => |v| v,
                        else => return self.fail("多字节读取需要局部槽", .{}),
                    };
                    self.vals[@backingInt(inst)] = mcsmir.v(base);
                    self.wide[@backingInt(inst)] = @as(u16, base) | (@as(u16, ln_b) << 8);
                    continue;
                }
                const src = try self.refLoc(ty_op.operand);
                // P1：值只被紧接的一条指令消费 → 直接把槽位置当值，省掉一次 mov。
                if (self.useCount(body, inst, idx) == 1) {
                    if (self.nextRealIdx(body, idx)) |ni| {
                        const ntag = self.air.instructions.items(.tag)[@backingInt(body[ni])];
                        const consumes = switch (ntag) {
                            .add, .add_safe, .add_wrap, .sub, .sub_safe, .sub_wrap, .store, .store_safe => true,
                            .cmp_lt, .cmp_lte, .cmp_gt, .cmp_gte, .cmp_eq, .cmp_neq => true,
                            .bit_and, .bit_or, .xor => true,
                            else => false,
                        };
                        if (consumes) {
                            self.vals[@backingInt(inst)] = src;
                            continue;
                        }
                    }
                }
                const r = try self.allocVreg();
                try self.ops.append(self.gpa, .{ .mov = .{ .dst = mcsmir.v(r), .src = src } });
                self.vals[@backingInt(inst)] = mcsmir.v(r);
            },

            .ret, .ret_safe => {
                if (self.is_isr) {
                    // ISR 尾声：恢复现场（逆序）+ reti。诊断开关同序言。
                    const no_save = no_isr_save;
                    if (!no_save) {
                        try self.ops.appendSlice(self.gpa, &.{
                            .{ .pop = .{ .dst = .{ .dir = 0x83 } } }, // DPH
                            .{ .pop = .{ .dst = .{ .dir = 0x82 } } }, // DPL
                            .{ .pop = .{ .dst = .{ .dir = 0xD0 } } }, // PSW
                            .{ .pop = .{ .dst = .{ .dir = 0xE0 } } }, // ACC
                        });
                    }
                    try self.ops.append(self.gpa, .{ .reti = {} });
                    self.saw_ret = true;
                    continue;
                }
                if (self.ret_byte) |rb| {
                    const operand = data.un_op;
                    if (operand.toIndex() == null and operand.toInterned() == null) {
                        return self.zcu.codegenFail(self.nav, "mcs2: ret 操作数无效", .{});
                    }
                    if (self.ret_wide > 1) {
                        // 多字节返回（SDCC 同款）：低字节序依次进 DPL/DPH/B/A。
                        const base = try self.wideOperand(operand, self.ret_wide);
                        var k: u8 = 0;
                        while (k < self.ret_wide) : (k += 1) {
                            try self.ops.append(self.gpa, .{ .store_dir = .{ .addr = mcsmir.abi.arg_regs[k], .src = mcsmir.v(base + k) } });
                        }
                    } else {
                        const loc = try self.refLoc(operand);
                        const already = switch (loc) {
                            .dir => |a| a == rb,
                            else => false,
                        };
                        if (!already) {
                            try self.ops.append(self.gpa, .{ .store_dir = .{ .addr = rb, .src = loc } });
                        }
                    }
                }
                try self.ops.append(self.gpa, .{ .ret = {} });
                self.saw_ret = true;
                return true;
            },


            .br => {
                // break / 跳块：目标 = 该块定义指令的“出口”标签。
                const br = data.br;
                // 带值的 br（if/switch 表达式）：先把值写进目标块的结果槽（内存 phi）。
                if (self.slotForBlock(br.block_inst)) |slot| {
                    if (self.air.typeOf(br.operand, &self.zcu.intern_pool).zigTypeTag(self.zcu) != .void) {
                        const n = slot.width;
                        const src = try self.wideOperand(br.operand, n);
                        var k: u8 = 0;
                        while (k < n) : (k += 1) try self.movTo(slot.base + k, mcsmir.v(src + k));
                    }
                }
                try self.ops.append(self.gpa, .{ .br = self.blockEnd(br.block_inst) });
                return true;
            },
            .repeat => {
                // 回边：跳回 loop 头。
                try self.ops.append(self.gpa, .{ .br = self.blockHead(data.repeat.loop_inst) });
                return true;
            },
            .cond_br => {
                try self.emitCondBr(inst);
                return true;
            },
            // switch（含 while(true) switch 的 loop 形态）：比较链降级，见 emitSwitch。
            .switch_br, .loop_switch_br => {
                try self.emitSwitch(inst);
            },
            .loop => {
                const blk = self.air.unwrapBlock(inst);
                try self.ops.append(self.gpa, .{ .label = self.blockHead(inst) });
                const inner = try self.emitBody(blk.body);
                const end_l = self.blockEnd(inst);
                // while(true)：body 终结且无人 break 到块尾 → 整个循环不会落空
                if (inner and !self.labelReferenced(end_l)) return true;
                try self.ops.append(self.gpa, .{ .label = end_l });
            },
            .block => {
                // 带返回值的块 = `if`/`switch` 表达式。用**内存 phi** 降级：
                // 块结果先分一个槽，每条跳向本块的 `br` 把值写进槽，块尾读槽当结果。
                // （不需要 phi 结点、也不需要活跃期分析——和本后端「值都在静态槽」一致。）
                const blk_ty = self.air.typeOfIndex(inst, &self.zcu.intern_pool);
                if (blk_ty.zigTypeTag(self.zcu) != .void) {
                    const n = try self.storageBytes(blk_ty, "块返回值");
                    const base: u8 = if (n > 1) try self.allocWide(n) else try self.allocVreg();
                    try self.block_slots.append(self.gpa, .{ .inst = inst, .base = base, .width = n });
                    const blk_v = self.air.unwrapBlock(inst);
                    _ = try self.emitBody(blk_v.body);
                    try self.ops.append(self.gpa, .{ .label = self.blockEnd(inst) });
                    self.vals[@backingInt(inst)] = mcsmir.v(base);
                    if (n > 1) self.wide[@backingInt(inst)] = @as(u16, base) | (@as(u16, n) << 8);
                    continue;
                }
                const blk = self.air.unwrapBlock(inst);
                const inner = try self.emitBody(blk.body);
                const end_l = self.blockEnd(inst);
                // 块内已终结且没人 break 到块尾 → 整个块也不会落空（while(true) 的常见形态）
                if (inner and !self.labelReferenced(end_l)) return true;
                try self.ops.append(self.gpa, .{ .label = end_l });
            },
            // ---- M2.5：内部调用 ----
            // 内部 ABI 与边界 ABI 完全一致（arg0 → DPL/DPH/B/A，其余 → 被调方 PARM 区，
            // 返回值同），所以 Zig↔Zig 与 Zig↔C 共用一条约定，不需要 thunk。
            // 又因为所有值都在 DSEG 静态槽，调用前**不用保存寄存器现场**，只处理两件事：
            //   ① B 若是本函数的 arg2（0xF0）会被被调方踩掉 → 存一份；
            //   ② 调用会踩 DPL/DPH → 之后用 dptr 的地方由 lower() 自己重建。
            .call, .call_always_tail, .call_never_tail, .call_never_inline => {
                const ci = self.air.unwrapCall(inst);
                const ip = &self.zcu.intern_pool;
                const callee_ip = ci.callee.toInterned();
                if (callee_ip == null) {
                    // ---- 间接调用：函数指针 / 把地址装进 u16 再强转 ----
                    var cty = self.air.typeOf(ci.callee, ip);
                    if (cty.zigTypeTag(self.zcu) == .pointer) cty = cty.childType(self.zcu);
                    const rty2 = cty.fnReturnType(self.zcu);
                    const rn2: u8 = if (rty2.zigTypeTag(self.zcu) == .void)
                        0
                    else
                        try self.storageBytes(rty2, "调用返回值");
                    // ① 目标地址先快照成 2 字节（后面摆参会踩 DPL/DPH）
                    const tgt = try self.wideOperand(ci.callee, 2);
                    const sv = try self.allocVreg();
                    // ② 实参快照（间接调用拿不到被调方的 PARM 符号 → 只能走 ABI 寄存器）
                    var total: usize = 0;
                    for (ci.args) |arg_ref| {
                        total += try self.storageBytes(self.air.typeOf(arg_ref, ip), "调用参数");
                    }
                    if (total > 4) return self.fail(
                        "间接调用（函数指针）只支持 ≤4 字节参数（合计），当前 {d} 字节——间接调用拿不到被调方的 PARM 区",
                        .{total},
                    );
                    // ③ 摆参：所有实参按字节顺序灌进 ABI 寄存器（合计 ≤4 字节，前面已校验）
                    var off: u8 = 0;
                    for (ci.args) |arg_ref| {
                        const aty = self.air.typeOf(arg_ref, ip);
                        const an = try self.storageBytes(aty, "调用参数");
                        const base = try self.wideOperand(arg_ref, an);
                        var k: u8 = 0;
                        while (k < an) : (k += 1) {
                            try self.ops.append(self.gpa, .{ .mov = .{
                                .dst = .{ .dir = mcsmir.abi.arg_regs[off + k] },
                                .src = mcsmir.v(base + k),
                            } });
                        }
                        off += an;
                    }
                    try self.ops.append(self.gpa, .{ .lcall_ind = .{ .target = tgt, .save = mcsmir.v(sv) } });
                    if (rn2 > 0) {
                        const dbase2 = try self.allocWide(rn2);
                        var kk: u8 = rn2;
                        while (kk > 0) {
                            kk -= 1;
                            try self.ops.append(self.gpa, .{ .load_dir = .{
                                .dst = mcsmir.v(dbase2 + kk),
                                .addr = mcsmir.abi.arg_regs[kk],
                            } });
                        }
                        self.vals[@backingInt(inst)] = mcsmir.v(dbase2);
                        if (rn2 > 1) self.wide[@backingInt(inst)] = @as(u16, dbase2) | (@as(u16, rn2) << 8);
                    }
                    continue;
                }
                const key = ip.indexToKey(callee_ip.?);
                var sym: []const u8 = undefined;
                var short: []const u8 = undefined;
                // 取函数地址再调用（callee 是 .ptr 指向具名函数）→ 解出符号走直调，
                // 比物化 2 字节地址再间接调更省。
                var resolved = false;
                if (key == .ptr) {
                    const nav = switch (key.ptr.base_addr) {
                        .nav => |n| n,
                        else => return self.fail("取地址调用的目标不是具名函数", .{}),
                    };
                    const mangled = try mangleNavSymbol(self.gpa, ip, nav);
                    defer self.gpa.free(mangled);
                    // 符号进符号池：调用符号要活到 mcs51 发射完，统一在 generate 末尾释放
                    sym = self.internSym(mangled) orelse return error.OutOfMemory;
                    // 短名直接用 interned 切片（以前这里每次调用 dupe 一份，SafeAllocator 报泄漏）
                    short = ip.getNav(nav).name.toSlice(ip);
                    resolved = true;
                }
                if (!resolved) {
                    switch (key) {
                        .func => |fi| {
                            const nav = fi.owner_nav;
                            const mangled = try mangleNavSymbol(self.gpa, ip, nav);
                            defer self.gpa.free(mangled);
                            sym = self.internSym(mangled) orelse return error.OutOfMemory;
                            short = ip.getNav(nav).name.toSlice(ip);
                        },
                        .@"extern" => |ex| {
                            // C 函数：SDCC 的符号就是 _名字
                            const nm = ex.name.toSlice(ip);
                            const owned = try std.fmt.allocPrint(self.gpa, "_{s}", .{nm});
                            defer self.gpa.free(owned);
                            sym = self.internSym(owned) orelse return error.OutOfMemory;
                            short = nm;
                        },
                        else => return self.fail("调用目标不是函数（{s}）", .{@tagName(key)}),
                    }
                }
                const callee_ty = self.air.typeOf(ci.callee, ip);
                const ret2 = callee_ty.fnReturnType(self.zcu);
                const ret_n: u8 = if (ret2.zigTypeTag(self.zcu) == .void)
                    0
                else
                    try self.storageBytes(ret2, "调用返回值");

                var saved_b: ?u8 = null;
                if (self.b_is_arg) {
                    saved_b = try self.allocVreg();
                    try self.ops.append(self.gpa, .{ .mov = .{ .dst = mcsmir.v(saved_b.?), .src = .{ .dir = 0xF0 } } });
                }
                // ① 先把**所有实参快照进 vreg 槽**：实参此刻可能就住在 DPL/DPH/B/A 里
                //   （本函数自己的参数，或被拷贝折叠映射过去），
                //   若边摆边取，摆 arg0 就会把还没搬走的 arg1..N 踩掉（实测 chain32 就是这样错的）。
                const nargs = ci.args.len;
                const bases = try self.gpa.alloc(u8, nargs);
                defer self.gpa.free(bases);
                const widths = try self.gpa.alloc(u8, nargs);
                defer self.gpa.free(widths);
                for (ci.args, 0..) |arg_ref, ai| {
                    const aty = self.air.typeOf(arg_ref, ip);
                    const an = try self.storageBytes(aty, "调用参数");
                    if (an > 4) return self.fail("参数超过 4 字节（多字节结构体）尚未支持", .{});
                    widths[ai] = an;
                    bases[ai] = try self.wideOperand(arg_ref, an);
                }
                // ② 再统一摆到 ABI 位置：arg0 进 ABI 寄存器，其余进 _被调短名_PARM_2 起的连续字节
                var spill: usize = 2;
                for (ci.args, 0..) |_, ai| {
                    const an = widths[ai];
                    const base = bases[ai];
                    var k: u8 = 0;
                    while (k < an) : (k += 1) {
                        // 调用点也要写被调方的 PARM 符号：名字进符号池（同一名字只留一份，
                        // 结束时统一释放）——以前这里直接 allocPrint 后扔掉，每次调用漏一份。
                        const psym = try std.fmt.allocPrint(self.gpa, "_{s}_PARM_{d}", .{ short, spill + k });
                        defer self.gpa.free(psym);
                        const kept = self.internSym(psym) orelse return error.OutOfMemory;
                        const dst: mcsmir.Byte = if (ai == 0)
                            .{ .dir = mcsmir.abi.arg_regs[k] }
                        else
                            .{ .sym = kept };
                        try self.ops.append(self.gpa, .{ .mov = .{ .dst = dst, .src = mcsmir.v(base + k) } });
                    }
                    if (ai > 0) spill += an;
                }
                try self.ops.append(self.gpa, .{ .lcall = .{ .sym = sym } });
                // 取返回值：DPL/DPH/B/A（低字节序）→ 新槽。
                // **必须从高字节往低读**：读 ACC 用的是 `mov a,0xE0`，而 ACC 就是 A 本身，
                // 先读 DPL/DPH/B 会把它踩掉（实测 ACC 返回 0x34 —— 其实是 B 的值）。
                if (ret_n > 0) {
                    const dbase = try self.allocWide(ret_n);
                    var kk: u8 = ret_n;
                    while (kk > 0) {
                        kk -= 1;
                        try self.ops.append(self.gpa, .{ .load_dir = .{
                            .dst = mcsmir.v(dbase + kk),
                            .addr = mcsmir.abi.arg_regs[kk],
                        } });
                    }
                    self.vals[@backingInt(inst)] = mcsmir.v(dbase);
                    if (ret_n > 1) self.wide[@backingInt(inst)] = @as(u16, dbase) | (@as(u16, ret_n) << 8);
                }
                if (saved_b) |sv| {
                    try self.ops.append(self.gpa, .{ .mov = .{ .dst = .{ .dir = 0xF0 }, .src = mcsmir.v(sv) } });
                }
            },

            .cmp_lt, .cmp_lt_optimized, .cmp_lte, .cmp_lte_optimized,
            .cmp_gt, .cmp_gt_optimized, .cmp_gte, .cmp_gte_optimized,
            .cmp_eq, .cmp_eq_optimized, .cmp_neq, .cmp_neq_optimized => {
                // 比较当 cond_br 的条件时不发码（emitCondBr 融合成 cmp_br / cmp_wide_br）。
                // 被当值用（return / 赋值形式）时物化成 0/1 字节：
                // 先置 0，条件成立就跳到「写 1」——用取反条件 + 一个落地标签。
                if (self.useCount(body, inst, idx) > 0) {
                    const cc = ccOf(tag).?;
                    const bin = data.bin_op;
                    const d = mcsmir.v(try self.allocVreg());
                    const l_true = self.tempLabel();
                    try self.ops.append(self.gpa, .{ .imm = .{ .dst = d, .value = 0 } });
                    const oty = self.air.typeOf(bin.lhs, &self.zcu.intern_pool);
                    const wide_cmp = if (self.intInfo(oty)) |oi| (oi.bytes > 1 or oi.signed) else false;
                    if (wide_cmp) {
                        const oi = self.intInfo(oty).?;
                        const lhs = try self.wideOperand(bin.lhs, oi.bytes);
                        const rhs = try self.wideOperand(bin.rhs, oi.bytes);
                        const tmp = try self.allocVreg();
                        try self.ops.append(self.gpa, .{ .cmp_wide_br = .{
                            .lhs = lhs,
                            .rhs = rhs,
                            .n = oi.bytes,
                            .tmp = mcsmir.v(tmp),
                            .cc = cc.invert(),
                            .signed = oi.signed,
                            .target = l_true,
                        } });
                    } else {
                        const lhs = try self.refLoc(bin.lhs);
                        const rhs = try self.refLoc(bin.rhs);
                        try self.ops.append(self.gpa, .{ .cmp_br = .{
                            .lhs = lhs,
                            .rhs = rhs,
                            .cc = cc.invert(),
                            .target = l_true,
                        } });
                    }
                    try self.ops.append(self.gpa, .{ .imm = .{ .dst = d, .value = 1 } });
                    try self.ops.append(self.gpa, .{ .label = l_true });
                    self.vals[@backingInt(inst)] = d;
                }
            },

            else => return self.zcu.codegenFail(
                self.nav,
                "mcs2: AIR 指令 `{s}` 尚未实现（M1 范围：arg/add_wrap/sub_wrap/ret）",
                .{@tagName(tag)},
            ),
        }
    }
    return false;
    }

};

pub fn generate(
    lf: *link.File,
    pt: Zcu.PerThread,
    func_index: InternPool.Index,
    air: *const Air,
    liveness: *const ?Air.Liveness,
) codegen.Error!Mir {
    _ = lf;
    // 会话级计数器（vreg 基址、标签域、临时标签）串行化。
    lockCodegen();
    defer unlockCodegen();
    _ = liveness;

    const zcu = pt.zcu;
    const gpa = zcu.gpa;
    const ip = &zcu.intern_pool;
    const func = zcu.funcInfo(func_index);
    const func_ty = Type.fromInterned(func.ty);
    const ret_ty = func_ty.fnReturnType(zcu);

    if (zcu.getTarget().cpu.arch != .mcs51) {
        return zcu.codegenFail(
            func.owner_nav,
            "mcs2: {s} 发射器尚未实现（251 排期 M2 之后）",
            .{@tagName(zcu.getTarget().cpu.arch)},
        );
    }

    // 返回类型：void 或 u8（走 DPL）。
    const lower_ret_byte: ?u8 = if (ret_ty.zigTypeTag(zcu) == .void)
        null
    else blk: {
        const rtt = ret_ty.zigTypeTag(zcu);
        const rbits: u64 = if (rtt == .int) ret_ty.bitSize(zcu) else if (rtt == .bool) 8 else 0;
        if ((rtt != .int and rtt != .bool) or rbits == 0 or rbits > 32) {
            return zcu.codegenFail(
                func.owner_nav,
                "mcs2: 返回类型 {s} 尚未实现（目前 void/≤32 位整数）",
                .{@tagName(ret_ty.zigTypeTag(zcu))},
            );
        }
        break :blk mcsmir.abi.dpl;
    };
    // 返回宽度：u16 走 DPL/DPH 两个字节。
    const lower_ret_wide: u8 = if (lower_ret_byte == null)
        1
    else switch (ret_ty.bitSize(zcu)) {
        16 => 2,
        32 => 4,
        else => 1,
    };

    // 中断函数检测：callconv(.{ .mcs51_interrupt = .{ .vector = n } })（M1.5）。
    // 向量号 1-based（STC 手册口径），8051 向量地址 = 0x0003 + 8*(n-1)；
    // 编译器自动发向量跳板（8 字节槽放 ljmp，函数体在别处）——驱动不再手写向量表。
    const cc = func_ty.fnCallingConvention(zcu);
    var isr_vector: u16 = 0xFFFF;
    switch (cc) {
        .mcs51_interrupt => |opts| isr_vector = opts.vector,
        else => {},
    }
    const is_isr = isr_vector != 0xFFFF;
    if (is_isr) {
        if (lower_ret_byte != null) {
            return zcu.codegenFail(func.owner_nav, "mcs2: 中断函数必须返回 void", .{});
        }
        if (isr_vector > 13) {
            return zcu.codegenFail(func.owner_nav, "mcs2: 中断号 {d} 超出 8051 范围（0-13）", .{isr_vector});
        }
        // 中断函数的 vreg 天然与主代码零交集：会话计数器只增不回收，
        // ISR 拿到的槽主代码从未引用（ADR-001 静态槽模型下的最小正确方案）。
    }

    const sym_name = try mangleNavSymbol(gpa, ip, func.owner_nav);
    defer gpa.free(sym_name);
    const short_name = try gpa.dupe(u8, ip.getNav(func.owner_nav).name.toSlice(ip));
    defer gpa.free(short_name);
    const label_base = session_label_base;
    session_label_base += @as(u32, @intCast(air.instructions.len)) * 2 + 2;
    var lw = Lower{
        .zcu = zcu,
        .gpa = gpa,
        .air = air,
        .nav = func.owner_nav,
        .sym_name = sym_name,
        .short_name = short_name,
        .ret_byte = lower_ret_byte,
        .label_base = label_base,
    };
    defer lw.ops.deinit(gpa);
    defer lw.parms.deinit(gpa);
    defer {
        for (lw.sym_pool.items) |s| gpa.free(s);
        lw.sym_pool.deinit(gpa);
    }
    defer lw.const_lines.deinit(gpa);
    defer lw.block_slots.deinit(gpa);

    const body = air.getMainBody();
    lw.vals = try gpa.alloc(?Loc, air.instructions.len);
    defer gpa.free(lw.vals);
    @memset(lw.vals, null);

    lw.ptr_vals = try gpa.alloc(?PtrRef, air.instructions.len);
    defer gpa.free(lw.ptr_vals);
    @memset(lw.ptr_vals, null);

    lw.needs_dptr = lw.airNeedsDptr();
    lw.ret_wide = lower_ret_wide;

    lw.wide = try gpa.alloc(?u16, air.instructions.len);
    defer gpa.free(lw.wide);
    @memset(lw.wide, null);
    // 关键：ISR 的尾声（pop + reti）靠这个字段判定；漏赋值会让 ISR 以 `ret` 结束、
    // 且不恢复现场（栈上留下 4 字节，打断主程序后必错）。
    lw.is_isr = is_isr;
    // 诊断开关：函数名以 _airdump 结尾 → 打印该函数的 AIR 序列（配合 PE 的 _fold 命名约定）。
    lw.dump_air = std.mem.indexOf(u8, short_name, "airdump") != null;

    if (is_isr and !no_isr_save) {
        // 现场保存：A/PSW/DPTR（M1 指令集用到的全部硬件寄存器；B 未用）。
        // 注意顺序与尾声严格相反。诊断开关 MCS2_NO_ISR_SAVE=1 可跳过。
        try lw.ops.appendSlice(gpa, &.{
            .{ .push = .{ .src = .{ .dir = 0xE0 } } }, // ACC
            .{ .push = .{ .src = .{ .dir = 0xD0 } } }, // PSW
            .{ .push = .{ .src = .{ .dir = 0x82 } } }, // DPL
            .{ .push = .{ .src = .{ .dir = 0x83 } } }, // DPH
        });
    }

    const body_terminated = try lw.emitBody(body);

    // M2.12：相邻拷贝折叠（去掉 mov vd,vs 的纯中转）。
    lw.foldCopies();

    // 位运算：RMW 折叠（load+op+store 同址 → 单指令 dir 级 RMW）。
    lw.foldDirRmw();

    // U2：位测试折叠（(SFR & 单比特) 比较 → jb/jnb）。
    lw.foldBitTests();

    // M2.4：循环旋转（top-test + 底部递减 → djnz）。
    try lw.rotateDjnz();

    // 部分求值（切片 A）：无参 + 纯内部计算 → 编译期算完，只留常量写回。
    // 激进优化必须显式开启：函数名以 `_fold` 结尾（如 fact_fold / sum_to_fold）。
    const fold_opt_in = std.mem.endsWith(u8, short_name, "_fold");
    if (!is_isr and lw.arg_cursor == 0 and fold_opt_in) {
        if (try lw.foldPure()) lw.saw_ret = true;
    }

    // M2.13：寄存器分配（PE 折叠成功时不必——常量写回没有热点值）。
    // M2.14 切片 1（基本块内槽位复用）**还没打通**，先关掉。已修掉的两个坑：
    //   ① 复用槽号落进 0–7 会被 `byteText` 渲染成 `rN` → 发出不存在的 `mov rN,rM`
    //      （现在复用槽从 8 号开始）；
    //   ② `.dec` 的载荷是裸 vreg 编号，`mapOpVregs` 不映射它 → 改名后编号越界
    //      （现在单独补一次映射）。
    // 但 `cat45` 仍然算错（值被提前复用），说明还有别的寿命/别名漏洞没堵——
    // 要专门一轮把 liveness 做扎实（含 .dec/.dec_br_nz/wide 块/调用点的边界）再开。
    // 指令内临时槽回收（`flushTempsKeep`）是安全的那部分，已保留。
    // lw.reuseSlots();
    lw.assignRegisters();

    // 没有 ret 也允许：只要 body 以 br 终结（如 while(true)），控制流不会落空。
    if (!lw.saw_ret and !body_terminated) {
        return zcu.codegenFail(func.owner_nav, "mcs2: 函数体缺少 ret", .{});
    }

    // 推进会话级基线，下一函数的 vreg 从这里继续。
    session_vreg_base +|= lw.nregs;

    // Function 组装，走与 selftest 完全相同的发射管线。
    const f: mcsmir.Function = .{
        .name = sym_name[1..], // lower 内部会再加 `_` 前缀
        .profile = .mcs51_sdcc,
        .nregs = lw.nregs,
        .vreg_base = session_vreg_base - lw.nregs,
        .ops = try lw.ops.toOwnedSlice(gpa),
        .parms = try lw.parms.toOwnedSlice(gpa),
    };

    // compile 之后 Op 序列与符号名都不再需要，就地释放（Debug SafeAllocator 门禁）。
    defer gpa.free(f.ops);
    // 参数区的符号名是 allocPrint 出来的，逐个释放（SafeAllocator 会查泄漏）。
    defer {
        for (f.parms) |psym| gpa.free(psym);
        gpa.free(f.parms);
    }
    const text = try mcs51.compileEx(f, gpa, false);
    defer gpa.free(text);

    var mir: Mir = .{};
    errdefer mir.deinit(gpa);
    try mir.text.appendSlice(gpa, text);

    // comptime 常量表的数据块跟在函数体后面（同一个汇编单元，符号可见）。
    if (lw.const_lines.items.len != 0) try mir.text.appendSlice(gpa, lw.const_lines.items);

    // 中断向量跳板：绝对段 VECTORS 内 .org 到向量地址发 ljmp（函数体在 CSEG 别处）。
    if (is_isr) {
        const vec_addr: u16 = 0x0003 + 8 * isr_vector;
        const vec_text = try std.fmt.allocPrint(
            gpa,
            "\n\t.area VECTORS (ABS,CODE)\n\t.org 0x{X:0>4}\n\tljmp {s}\n\t.area CSEG (CODE)\n",
            .{ vec_addr, sym_name },
        );
        defer gpa.free(vec_text);
        try mir.text.appendSlice(gpa, vec_text);
    }
    return mir;
}

/// 延迟符号（编译器内置函数）暂不支持。
pub fn generateLazy(
    lf: *link.File,
    pt: Zcu.PerThread,
    lazy_sym: link.File.LazySymbol,
    atom_id: link.File.AtomId,
    w: *std.Io.Writer,
    debug_output: link.File.DebugInfoOutput,
) link.EmitError!void {
    _ = lf;
    _ = atom_id;
    _ = w;
    _ = debug_output;
    return pt.zcu.codegenFailType(
        lazy_sym.ty,
        "mcs2: lazy symbols（编译器内置函数）尚未实现",
        .{},
    );
}

/// 函数符号修饰：`_<fqn>`，非标识符字符替换为 `_`。
pub fn mangleNavSymbol(
    gpa: std.mem.Allocator,
    ip: *const InternPool,
    nav: InternPool.Nav.Index,
) std.mem.Allocator.Error![]u8 {
    const fqn = ip.getNav(nav).fqn.toSlice(ip);
    var out = try std.ArrayList(u8).initCapacity(gpa, fqn.len + 1);
    errdefer out.deinit(gpa);
    out.appendAssumeCapacity('_');
    for (fqn) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_';
        out.appendAssumeCapacity(if (ok) c else '_');
    }
    return out.toOwnedSlice(gpa);
}
