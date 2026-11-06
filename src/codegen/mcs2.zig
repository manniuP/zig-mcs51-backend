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
const diag = @import("mcs2/diag.zig");
const factor = @import("mcs2/factor.zig");
const air_expr = @import("mcs2/air_expr.zig");

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
/// 实验开关：true = 操作数是存储别名时禁止原地写回（正确但 DSEG 涨到 110B，装不下）。
const forbid_alias_reuse: bool = false;
/// 诊断：MCS2_NO_REUSE_WIDE=1 关掉「宽运算原地写回」（定位 reuseWideDst 的误判）。
var no_reuse_wide: bool = false; // 诊断开关：诊断时手工改 true
/// 实验开关：只读消费者的结果分到临时槽。实测 DSEG 98→115（更差），默认关。
const scratch_results: bool = true;
/// 记账开关：打印每个永久 allocWide 块（AIR 指令、槽基址、宽度、最后读取点）。
/// 默认关：诊断输出会混进编译错误信息，干扰「改写建议」的可读性。
const account_wide: bool = false;
/// 重复复杂算法压缩总开关：改 false 重编即可得到「全部内联」的尺寸基线。
const enable_factor: bool = true;
/// 统计开关：打印每个 .alloc 的逃逸判定。
const alloc_report: bool = false; // 统计开关（看 alloc 逃逸情况时临时改 true） // 记账开关

/// 一个 8 位值的位置（M1：全部经 direct 寻址可达）。
const Loc = mcsmir.Byte;

/// 指针值：固定地址（`@ptrFromInt` 常量）、符号基址（全局/静态变量），
/// 各自再带「+ 运行期下标 × scale」。
/// 多维下标的一项：addr += idx * scale
const DTerm = struct { idx: Loc = .{ .imm = 0 }, scale: u32 = 1 };

/// 多维下标的基址
const ChainBase = union(enum) {
    fixed: u64,
    sym: struct { sym: []const u8, off: u64 = 0 },
    rt: struct { lo: Loc, hi: Loc, off: u64 = 0 },
};

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
    /// **运行期指针做基址**：地址在两个槽里（低字节在前）。`p[i]` 的 p 是参数/指针变量。
    rt: struct { lo: Loc, hi: Loc, off: u64 = 0 },
    /// 运行期指针 + 运行期下标：地址 = base + off + idx*scale
    rt_elem: struct { lo: Loc, hi: Loc, off: u64 = 0, idx: Loc, scale: u8 = 1 },
    /// **多维**（屏幕帧缓冲 `fb[z][y][x]` 这种）：地址 = 基址 + Σ idx_k * scale_k。
    /// 已有的单下标形态继续走上面几个变体（更省），第二次下标才升级成链。
    chain: struct { base: ChainBase, n: u8 = 0, terms: [4]DTerm = .{ .{}, .{}, .{}, .{} } },
};

/// 带返回值块的结果槽：`inst` 是块指令，`base/width` 是 DSEG 槽。
const BlockSlot = struct { inst: Air.Inst.Index, base: u8, width: u8 };

/// M1 的线性降级器。不做活跃分析：`.arg` 原地用 ABI 寄存器（零序言），
/// 双目结果默认落新 vreg，唯一的单消费者优化是「ret 前看一眼」——
/// 结果直接写 DPL，省一次 vreg 往返（`add8` 预算内的关键一招）。
/// 到期自动回收的宽结果段。
///
/// `last` 用 **AIR 指令编号**（不是 body 下标），`body` 记住分配时所在 body——
/// 嵌套块的指令编号与父 body 的下标不是一套尺度，跨 body 比对毫无意义。
/// 早期就是拿「指令编号」去和「body 下标」比，导致该留的被提前回收、
/// 该还的永远不还（宽局部量回收三次回退的根因）。跨 body 一律不回收，
/// 由 `freeScratchOfBody` 在 body 退出时整段清掉。
const ScratchRun = struct { base: u8 = 0, n: u8 = 0, last: usize = 0, body: usize = 0 };

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
    /// 已判成尾调用的那条 `ret`（发射到它时直接跳过：控制流已经在 `ljmp` 处走了）。
    tail_ret: ?Air.Inst.Index = null,
    /// 本函数的标签基址（跨函数不复用，避免汇编符号重名）。
    label_base: u32 = 0,
    /// 源码里的真实参数名（改写建议用，`n` / `m` 而不是 `a0` / `a1`）。
    /// 拿不到时保持 null，渲染退回 a0/a1。
    param_names: ?[]const []const u8 = null,
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
    /// 每个临时段属于哪条指令（生命周期判定用）：owner 还有后续读者就不能回收。
    temp_owner: [24]Air.Inst.Index = @splat(@enumFromInt(0)),
    /// 短寿命 scratch：按 AIR 最后读取点回收（Kimi 2026-11-02 的方案）。
    /// 到期自动回收的宽结果段（布局见 `ScratchRun`）。
    scratch_runs: [32]ScratchRun = @splat(.{}),
    scratch_n: u8 = 0,
    /// 当前正在发射的 body（scratch 生命周期按它分区）。
    cur_body: []const Air.Inst.Index = &.{},
    /// 本条指令的结果是否允许放 scratch（由 emitBody 每条指令算好）。
    cur_scratch_ok: bool = false,
    /// 正在 lower 的指令（temp 分配时记录 owner）。
    cur_inst: Air.Inst.Index = @enumFromInt(0),
    temp_n: u8 = 0,
    /// arg2 是否落在 B 寄存器（0xF0）。MUL/DIV 会破坏 B，用到时要保存/恢复。
    b_is_arg: bool = false,
    /// 本模块是否用到 dptr（取址/解引用）。用到时 arg0（DPL）必须先搬进 vreg：
    /// 0x82 同时是 DPTR 低字节，地址计算会把它踩掉。
    needs_dptr: bool = false,
    /// MCS2_DUMP_AIR 环境变量：打印 AIR 指令序列（诊断用）。
    dump_air: bool = false,
    /// 当前函数类型：生成「改写建议」时要拿真实的形参类型与返回类型。
    fn_ty: Type = undefined,
    /// 安全档（`ReleaseSafe`）的共享停机块标签：溢出检查命中就跳到这里。
    /// 懒分配——只有真正发过检查的函数才有这块尾代码，尺寸档零开销。
    panic_label: ?u32 = null,
    /// 安全档越界 / unreachable 的停机块（与溢出停机分用不同诊断标记）。
    trap_label: ?u32 = null,

    /// 存储宽度（**不是**算术宽度）：≤8 位一律 1 字节容器（u1/u5 这类只能当值存放），
    /// 16/32 按宽度。算术闸门仍然是 requireIntWidth（只认 8/16/32），
    /// 所以「能存」不会变成「能静默错算」。
    fn storageBytes(self: *Lower, ty: Type, comptime what: []const u8) codegen.Error!u8 {
        // mcs51 的指针就是 2 字节地址（arg0 时在 DPL/DPH，其余在 PARM 两字节）。
        if (ty.zigTypeTag(self.zcu) == .pointer) return 2;
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

    /// 一个类型占多少字节（数组 = 各维乘积 × 元素宽）。多维下标的**步长**要整块大小，
    /// 不能只取最内层元素（`[32][64]u16` 的步长是 4096，不是 2）。
    fn pointeeBytes(self: *Lower, ty: Type, comptime what: []const u8) codegen.Error!u32 {
        var t = ty;
        var n: u32 = 1;
        while (t.zigTypeTag(self.zcu) == .array) {
            n *= @intCast(t.arrayLen(self.zcu));
            if (n > 0x10000) return self.fail("{s}：元素跨度超过 64 KB", .{what});
            t = t.childType(self.zcu);
        }
        const eb = try self.storageBytes(t, what);
        return n * eb;
    }

    /// 取下标：常量直接成 imm；16 位下标拆成低/高两个槽（多维链按项加）。
    const IndexSlot = struct { lo: Loc, hi: ?Loc = null };
    /// 宽度按**实际槽宽**（`wide` 表）判断，不看类型：Zig 把下标从 u8/u16 转成 usize(24 位)，
    /// 但 int_cast 是透传，槽里仍是 1 或 2 字节 —— 按类型判断会读到邻槽。
    fn indexLoc(self: *Lower, ref: Air.Inst.Ref) codegen.Error!IndexSlot {
        if (self.constU8(ref)) |k| return .{ .lo = .{ .imm = k } };
        if (self.wideOf(ref)) |w| {
            const n: u8 = @truncate(w >> 8);
            if (n >= 2) {
                const base: u8 = @truncate(w & 0xFF);
                return .{ .lo = mcsmir.v(base), .hi = mcsmir.v(base + 1) };
            }
        }
        return .{ .lo = try self.refLoc(ref) };
    }

    /// 「多维链」追加一维（新下标可以占 1 或 2 个字节）。
    /// 16 位下标拆成两项：低字节×步长 + 高字节×(步长<<8) —— 只做 8×8 MUL，不做 16×16。
    fn chainAppend(self: *Lower, base: ChainBase, terms: []const DTerm, idx: Loc, sc: u32, idx_hi: ?Loc) codegen.Error!PtrRef {
        var c = PtrRef{ .chain = .{ .base = base } };
        var n: u8 = 0;
        for (terms) |t| {
            if (n >= 3) return self.fail("多维下标项过多", .{});
            c.chain.terms[n] = t;
            n += 1;
        }
        c.chain.terms[n] = .{ .idx = idx, .scale = sc };
        n += 1;
        if (idx_hi) |hi| {
            const hs = (sc << 8) & 0xFFFF;
            if (hs != 0) {
                c.chain.terms[n] = .{ .idx = hi, .scale = hs };
                n += 1;
            }
        }
        c.chain.n = n;
        return c;
    }

    /// 在已有基址上再加一维（统一的「取元素地址」规则）。
    /// 单下标变体的 scale/idx 都是 u8：**步长 > 255 或 16 位下标** 只能升级成链。
    fn indexedRef(self: *Lower, pr: PtrRef, idx: Loc, idx_hi: ?Loc, sc: u32) codegen.Error!PtrRef {
        if (sc > 255 or idx_hi != null) return switch (pr) {
            .fixed => |b| try self.chainAppend(.{ .fixed = b }, &.{}, idx, sc, idx_hi),
            .sym_off => |s| try self.chainAppend(.{ .sym = .{ .sym = s.sym, .off = s.off } }, &.{}, idx, sc, idx_hi),
            .rt => |r| try self.chainAppend(.{ .rt = .{ .lo = r.lo, .hi = r.hi, .off = r.off } }, &.{}, idx, sc, idx_hi),
            .elem => |e| try self.chainAppend(.{ .fixed = e.base }, &.{.{ .idx = e.idx, .scale = e.scale }}, idx, sc, idx_hi),
            .elem_sym => |e| try self.chainAppend(.{ .sym = .{ .sym = e.sym, .off = e.off } }, &.{.{ .idx = e.idx, .scale = e.scale }}, idx, sc, idx_hi),
            .rt_elem => |e| try self.chainAppend(.{ .rt = .{ .lo = e.lo, .hi = e.hi, .off = e.off } }, &.{.{ .idx = e.idx, .scale = e.scale }}, idx, sc, idx_hi),
            .chain => |c| try self.chainAppend(c.base, c.terms[0..c.n], idx, sc, idx_hi),
            .code_sym, .code_elem_sym => return self.failFix(.const_multi_dim, "const 表的多维下标暂不支持（只有一维）", .{}),
        };
        return switch (pr) {
            .fixed => |b| .{ .elem = .{ .base = b, .idx = idx, .scale = @intCast(sc) } },
            .sym_off => |s| .{ .elem_sym = .{ .sym = s.sym, .off = s.off, .idx = idx, .scale = @intCast(sc) } },
            .code_sym => |s| .{ .code_elem_sym = .{ .sym = s.sym, .off = s.off, .idx = idx, .scale = @intCast(sc) } },
            .rt => |r| .{ .rt_elem = .{ .lo = r.lo, .hi = r.hi, .off = r.off, .idx = idx, .scale = @intCast(sc) } },
            .elem => |e| try self.chainAppend(.{ .fixed = e.base }, &.{.{ .idx = e.idx, .scale = e.scale }}, idx, sc, null),
            .elem_sym => |e| try self.chainAppend(.{ .sym = .{ .sym = e.sym, .off = e.off } }, &.{.{ .idx = e.idx, .scale = e.scale }}, idx, sc, null),
            .rt_elem => |e| try self.chainAppend(.{ .rt = .{ .lo = e.lo, .hi = e.hi, .off = e.off } }, &.{.{ .idx = e.idx, .scale = e.scale }}, idx, sc, null),
            .chain => |c| try self.chainAppend(c.base, c.terms[0..c.n], idx, sc, null),
            .code_elem_sym => return self.failFix(.const_multi_dim, "const 表的多维下标暂不支持（只有一维）", .{}),
        };
    }

    /// 多维链 → DPTR：先装基址，再逐维 `dptr += idx*scale`。
    fn emitDptrChain(self: *Lower, base: ChainBase, terms: []const DTerm, k: u8) codegen.Error!void {
        switch (base) {
            .fixed => |b| {
                const a: u16 = @truncate(b + k);
                try self.ops.append(self.gpa, .{ .store_dir = .{ .addr = 0x82, .src = .{ .imm = @truncate(a) } } });
                try self.ops.append(self.gpa, .{ .store_dir = .{ .addr = 0x83, .src = .{ .imm = @truncate(a >> 8) } } });
            },
            .sym => |s| try self.ops.append(self.gpa, .{ .lea_dptr_sym = .{ .sym = s.sym, .off = @truncate(s.off + k) } }),
            .rt => |r| {
                try self.ops.append(self.gpa, .{ .add = .{ .dst = .{ .dir = 0x82 }, .lhs = r.lo, .rhs = .{ .imm = @truncate(r.off + k) } } });
                try self.ops.append(self.gpa, .{ .addc = .{ .dst = .{ .dir = 0x83 }, .lhs = r.hi, .rhs = .{ .imm = @truncate((r.off + k) >> 8) } } });
            },
        }
        for (terms) |t| {
            try self.ops.append(self.gpa, .{ .dptr_add_scaled = .{ .idx = t.idx, .scale = @intCast(t.scale) } });
        }
    }
    /// DPL/DPH = base(16 位，两个槽) + off [+ idx*scale]。
    /// 全部用 add/addc 逐字节搭：**不碰 B**（B 可能载着 arg2），也不需要 mul。
    fn emitDptrFromRt(self: *Lower, lo: Loc, hi: Loc, off: u64, idx: ?Loc, scale: u8) codegen.Error!void {
        const o: u16 = @truncate(off);
        try self.ops.append(self.gpa, .{ .add = .{
            .dst = .{ .dir = 0x82 },
            .lhs = lo,
            .rhs = .{ .imm = @truncate(o) },
        } });
        try self.ops.append(self.gpa, .{ .addc = .{
            .dst = .{ .dir = 0x83 },
            .lhs = hi,
            .rhs = .{ .imm = @truncate(o >> 8) },
        } });
        if (idx) |ix| {
            var s: u8 = 0;
            while (s < scale) : (s += 1) {
                try self.ops.append(self.gpa, .{ .add = .{
                    .dst = .{ .dir = 0x82 },
                    .lhs = .{ .dir = 0x82 },
                    .rhs = ix,
                } });
                try self.ops.append(self.gpa, .{ .addc = .{
                    .dst = .{ .dir = 0x83 },
                    .lhs = .{ .dir = 0x83 },
                    .rhs = .{ .imm = 0 },
                } });
            }
        }
    }

    /// 读指针 pr 的第 k 字节到槽 dst（多种基址形态统一在这里）。
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
            // 运行期指针：DPL/DPH = base + off + idx*scale，再 movx。
            .rt => |r| {
                try self.emitDptrFromRt(r.lo, r.hi, r.off + k, null, 1);
                try self.ops.append(self.gpa, .{ .load_xdata_dptr = .{ .dst = mcsmir.v(dst) } });
            },
            .rt_elem => |e| {
                try self.emitDptrFromRt(e.lo, e.hi, e.off + k, e.idx, e.scale);
                try self.ops.append(self.gpa, .{ .load_xdata_dptr = .{ .dst = mcsmir.v(dst) } });
            },
            // 多维（`fb[z][y][x]`）：基址 + 各维偏移，逐项加到 DPTR 上。
            .chain => |c| {
                try self.emitDptrChain(c.base, c.terms[0..c.n], k);
                try self.ops.append(self.gpa, .{ .load_xdata_dptr = .{ .dst = mcsmir.v(dst) } });
            },
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
            .rt => |r| {
                try self.emitDptrFromRt(r.lo, r.hi, r.off + k, null, 1);
                try self.ops.append(self.gpa, .{ .store_xdata_dptr = .{ .src = src } });
            },
            .rt_elem => |e| {
                try self.emitDptrFromRt(e.lo, e.hi, e.off + k, e.idx, e.scale);
                try self.ops.append(self.gpa, .{ .store_xdata_dptr = .{ .src = src } });
            },
            .chain => |c| {
                try self.emitDptrChain(c.base, c.terms[0..c.n], k);
                try self.ops.append(self.gpa, .{ .store_xdata_dptr = .{ .src = src } });
            },
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

    /// 尾调用判定：本指令的结果被**紧接的** `ret` 原样返回？
    /// 命中就返回那条 `ret` 的指令号（发射时跳过它——前面已经 `ljmp` 走掉了）。
    /// `has_result=false` 表示被调方返回 void：这时 `ret` 的操作数也必须是 void，
    /// 否则我们是"丢掉调用结果、返回别的值"，不能当尾调用。
    fn tailRetOf(self: *Lower, body: []const Air.Inst.Index, idx: usize, inst: Air.Inst.Index, has_result: bool) ?Air.Inst.Index {
        const ni = self.nextRealIdx(body, idx) orelse return null;
        const ri = body[ni];
        if (self.air.instructions.items(.tag)[@backingInt(ri)] != .ret) return null;
        const rop = self.air.instructions.items(.data)[@backingInt(ri)].un_op;
        if (has_result) {
            const rop_idx = rop.toIndex() orelse return null;
            if (rop_idx != inst) return null;
        } else if (rop.toIndex() != null) return null;
        return ri;
    }

    // ---- M1：AIR → Zig 源码（编译期改写建议用） ----
    //
    // 只覆盖整数算术 / 比较 / 转换的白名单，**任何一处不认识就整条返回 null**，
    // 调用方据此退回带占位符的骨架。改写建议宁可少说，也不能给用户一段
    // 语义不对的代码照着抄。

    const MAX_SRC_DEPTH = 6;

    /// 复合表达式加括号；原子（标识符 / 数字 / 已带括号的整体）原样返回。
    /// 只在**顶层**看到运算符才包括号，避免 `f((n - 1))` 变成 `(f((n - 1)))`。
    fn srcParen(gpa: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]u8 {
        var depth: i32 = 0;
        for (s) |c| switch (c) {
            '(', '[' => depth += 1,
            ')', ']' => depth -= 1,
            ' ', '+', '-', '*', '/', '%', '&', '|', '^', '<', '>', '~' => {
                if (depth == 0) return std.fmt.allocPrint(gpa, "({s})", .{s});
            },
            else => {},
        };
        return gpa.dupe(u8, s);
    }

    /// 二元运算的源码运算符；不是可渲染的算术/位运算返回 null。
    fn binOpStr(tag: Air.Inst.Tag) ?[]const u8 {
        return switch (tag) {
            .add, .add_safe, .add_optimized => "+",
            .add_wrap => "+%",
            .sub, .sub_safe, .sub_optimized => "-",
            .sub_wrap => "-%",
            .mul, .mul_safe, .mul_optimized => "*",
            .mul_wrap => "*%",
            .div_trunc, .div_trunc_optimized => "/",
            .rem, .rem_optimized => "%",
            .bit_and => "&",
            .bit_or => "|",
            .xor => "^",
            .shl, .shl_exact => "<<",
            .shr, .shr_exact => ">>",
            else => null,
        };
    }

    fn isCallTag(tag: Air.Inst.Tag) bool {
        return switch (tag) {
            .call, .call_always_tail, .call_never_tail, .call_never_inline => true,
            else => false,
        };
    }

    fn renderBinSrc(
        self: *Lower,
        gpa: std.mem.Allocator,
        lhs: Air.Inst.Ref,
        rhs: Air.Inst.Ref,
        tag: air_expr.Tag,
        depth: u8,
    ) std.mem.Allocator.Error!?[]u8 {
        const l = (try self.renderRefSrc(gpa, lhs, depth + 1)) orelse return null;
        defer gpa.free(l);
        const r = (try self.renderRefSrc(gpa, rhs, depth + 1)) orelse return null;
        defer gpa.free(r);
        const lp = try srcParen(gpa, l);
        defer gpa.free(lp);
        const rp = try srcParen(gpa, r);
        defer gpa.free(rp);
        return air_expr.render(gpa, tag, .{ .lhs = lp, .rhs = rp });
    }

    /// 把一条 AIR 引用渲染成 Zig 表达式。返回新分配的字符串（调用方释放）。
    /// 不支持的形态一律 null。
    fn renderRefSrc(
        self: *Lower,
        gpa: std.mem.Allocator,
        ref: Air.Inst.Ref,
        depth: u8,
    ) std.mem.Allocator.Error!?[]u8 {
        if (depth > MAX_SRC_DEPTH) return null;
        if (ref.toInterned()) |ip_index| {
            const key = self.zcu.intern_pool.indexToKey(ip_index);
            return switch (key) {
                .int => |int| switch (int.storage) {
                    .u64 => |v| try std.fmt.allocPrint(gpa, "{d}", .{v}),
                    .i64 => |v| if (v < 0)
                        try std.fmt.allocPrint(gpa, "-{d}", .{-v})
                    else
                        try std.fmt.allocPrint(gpa, "{d}", .{v}),
                    else => null,
                },
                else => null,
            };
        }
        const idx = ref.toIndex() orelse return null;
        const tag = self.air.instructions.items(.tag)[@backingInt(idx)];
        const d = self.air.instructions.items(.data)[@backingInt(idx)];
        switch (tag) {
            .arg => {
                const a = d.arg;
                if (self.param_names) |ns| {
                    if (a.zir_param_index < ns.len) return try gpa.dupe(u8, ns[a.zir_param_index]);
                }
                return try std.fmt.allocPrint(gpa, "a{d}", .{a.zir_param_index});
            },
            // 递归调用本身：名字就是当前函数名（只在自递归场景里用，见调用方）。
            .call, .call_always_tail, .call_never_tail, .call_never_inline => {
                const ci = self.air.unwrapCall(idx);
                var out: std.ArrayListUnmanaged(u8) = .empty;
                errdefer out.deinit(gpa);
                try out.appendSlice(gpa, self.short_name);
                try out.append(gpa, '(');
                for (ci.args, 0..) |a, i| {
                    if (i > 0) try out.appendSlice(gpa, ", ");
                    const s = (try self.renderRefSrc(gpa, a, depth + 1)) orelse return null;
                    defer gpa.free(s);
                    const p = try srcParen(gpa, s);
                    defer gpa.free(p);
                    try out.appendSlice(gpa, p);
                }
                try out.append(gpa, ')');
                return try out.toOwnedSlice(gpa);
            },
            .int_cast, .int_cast_safe, .trunc => {
                const s = (try self.renderRefSrc(gpa, d.ty_op.operand, depth + 1)) orelse return null;
                defer gpa.free(s);
                const p = try srcParen(gpa, s);
                defer gpa.free(p);
                return air_expr.render(gpa, if (tag == .trunc) .trunc else .int_cast, .{ .operand = p });
            },
            .not => {
                const s = (try self.renderRefSrc(gpa, d.un_op, depth + 1)) orelse return null;
                defer gpa.free(s);
                const p = try srcParen(gpa, s);
                defer gpa.free(p);
                return air_expr.render(gpa, .not_, .{ .operand = p });
            },
            else => {},
        }
        // 二元：算术 / 位运算 / 比较都是 `bin_op` 载荷。
        if (binOpStr(tag)) |ops| {
            _ = ops;
            const tag2: air_expr.Tag = switch (tag) {
                .add, .add_safe, .add_optimized => .add,
                .add_wrap => .add_wrap,
                .sub, .sub_safe, .sub_optimized => .sub,
                .sub_wrap => .sub_wrap,
                .mul, .mul_safe, .mul_optimized => .mul,
                .mul_wrap => .mul_wrap,
                .div_trunc, .div_trunc_optimized => .div_trunc,
                .rem, .rem_optimized => .rem,
                .bit_and => .bit_and,
                .bit_or => .bit_or,
                .xor => .xor,
                .shl, .shl_exact => .shl,
                .shr, .shr_exact => .shr,
                else => return null,
            };
            return try self.renderBinSrc(gpa, d.bin_op.lhs, d.bin_op.rhs, tag2, depth);
        }
        switch (tag) {
            .cmp_lt, .cmp_lt_optimized => return try self.renderBinSrc(gpa, d.bin_op.lhs, d.bin_op.rhs, .cmp_lt, depth),
            .cmp_lte, .cmp_lte_optimized => return try self.renderBinSrc(gpa, d.bin_op.lhs, d.bin_op.rhs, .cmp_lte, depth),
            .cmp_gt, .cmp_gt_optimized => return try self.renderBinSrc(gpa, d.bin_op.lhs, d.bin_op.rhs, .cmp_gt, depth),
            .cmp_gte, .cmp_gte_optimized => return try self.renderBinSrc(gpa, d.bin_op.lhs, d.bin_op.rhs, .cmp_gte, depth),
            .cmp_eq, .cmp_eq_optimized => return try self.renderBinSrc(gpa, d.bin_op.lhs, d.bin_op.rhs, .cmp_eq, depth),
            .cmp_neq, .cmp_neq_optimized => return try self.renderBinSrc(gpa, d.bin_op.lhs, d.bin_op.rhs, .cmp_neq, depth),
            else => return null,
        }
    }

    /// 非尾递归的现场还原：整条 return 表达式 + 递归实参 + 「调用之后的那一步」。
    /// 只在函数**只有一条 ret** 时还原——多出口时最后一条未必是当前路径，
    /// 说错了比不说更糟。
    fn renderNontailExtra(
        self: *Lower,
        gpa: std.mem.Allocator,
        call_inst: Air.Inst.Index,
    ) std.mem.Allocator.Error!?diag.Extra {
        const body = self.air.getMainBody();
        var ret_inst: ?Air.Inst.Index = null;
        var ret_n: usize = 0;
        for (body) |bi| {
            const t = self.air.instructions.items(.tag)[@backingInt(bi)];
            if (t == .ret or t == .ret_safe) {
                ret_n += 1;
                ret_inst = bi;
            }
        }
        if (ret_n != 1) return null;
        const rop = self.air.instructions.items(.data)[@backingInt(ret_inst.?)].un_op;
        const expr = (try self.renderRefSrc(gpa, rop, 0)) orelse return null;

        var post: []const u8 = "";
        if (rop.toIndex()) |ri| {
            const t2 = self.air.instructions.items(.tag)[@backingInt(ri)];
            const d2 = self.air.instructions.items(.data)[@backingInt(ri)];
            if (binOpStr(t2)) |ops| {
                const lhs_is_call = if (d2.bin_op.lhs.toIndex()) |li| li == call_inst else false;
                if (lhs_is_call) {
                    const r = (try self.renderRefSrc(gpa, d2.bin_op.rhs, 1)) orelse return null;
                    const rp = try srcParen(gpa, r);
                    post = try std.fmt.allocPrint(gpa, "{s} {s}", .{ ops, rp });
                }
            }
        }

        const ci = self.air.unwrapCall(call_inst);
        var abuf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer abuf.deinit(gpa);
        for (ci.args, 0..) |a, i| {
            if (i > 0) try abuf.appendSlice(gpa, ", ");
            const s = (try self.renderRefSrc(gpa, a, 1)) orelse return null;
            const p = try srcParen(gpa, s);
            try abuf.appendSlice(gpa, p);
        }
        return .{ .expr = expr, .post = post, .args_src = try abuf.toOwnedSlice(gpa) };
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
        self.temp_owner[self.temp_n] = self.cur_inst;
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
        // 结果只被只读消费者吃 → 走 scratch（最后读取点之后自动还池）。
        if (scratch_results and self.cur_scratch_ok) return self.allocScratch(n, self.cur_inst);
        const base = try self.allocSlots(n, false);
        if (account_wide) {
            const t = self.air.instructions.items(.tag)[@backingInt(self.cur_inst)];
            std.debug.print("WIDE fn={s} tag={s} inst={d} base={d} n={d} last={d}\n", .{ self.short_name, @tagName(t), @backingInt(self.cur_inst), base, n, self.airLastRead(self.cur_inst) });
        }
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
            if (from < n) {
                // 第一个高位直接 sex 进目标，其余从它复制 —— 省掉一个中转槽和一条 mov。
                // 原来：sex → 临时槽 e；再 mov dst+i, e（i 全遍历）。
                try self.ops.append(self.gpa, .{ .sex = .{ .dst = mcsmir.v(dst + from), .src = mcsmir.v(src_top) } });
                i = from + 1;
                while (i < n) : (i += 1) try self.movTo(dst + i, mcsmir.v(dst + from));
            }
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
        // 内部工作副本只在本次乘法里用（结果另有一块）→ 用临时槽，指令结束就还池。
        // 原来用 allocWide 会永久占 n 字节：hypot 里两次 u32 乘法白扔 8 B。
        const t = try self.allocTempWide(n);
        const ctr = try self.allocSlots(1, true);
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
    /// 「结果原地写回 lhs」的判定：lhs 在本条指令之后不再被读、且它本来就是 n 字节块。
    /// 每个二元宽运算都新开 n 个槽是 DSEG 的主要来源之一（CORDIC 的 `x -= y` 尤其多）。
    /// 注意必须要求 `a` 就是 lhs 自己的块基址 —— 宽度不等时 wideOperand 会拷进临时槽，
    /// 那种槽在指令结束就被回收，不能当结果。
    fn reuseWideDst(self: *Lower, body: []const Air.Inst.Index, idx: usize, lhs: Air.Inst.Ref, a: u8, n: u8) bool {
        if (no_reuse_wide) return false;
        const w = self.wideOf(lhs) orelse return false;
        if (@as(u8, @truncate(w >> 8)) != n) return false;
        if (@as(u8, @truncate(w & 0xFF)) != a) return false;
        const alias = self.wideIsAlias(lhs, n);
        // ① 操作数是**存储别名**（变量槽）：只能按「紧接着存回同一个局部槽」放行。
        //    用引用计数在这里是错的 —— 变量每次读都重新 load，那条 load 永远只被本指令用，
        //    于是计数恒为 0，`n >= res + bit` 就会把结果写进 res 的存储（2026-11-02 的 bug）。
        if (alias) {
            if (idx + 1 >= body.len) return false;
            const next = body[idx + 1];
            const next_tag = self.air.instructions.items(.tag)[@backingInt(next)];
            switch (next_tag) {
                .store, .store_safe => {},
                else => { return false; },
            }
            const st = self.air.instructions.items(.data)[@backingInt(next)].bin_op;
            const rhs_i = st.rhs.toIndex() orelse return false;
            if (@backingInt(rhs_i) != @backingInt(body[idx])) return false;
            if (self.ptrRefOf(st.lhs) != null) { return false; }
            const dest = self.refLoc(st.lhs) catch return false;
            const dslot: u8 = switch (dest) {
                .vreg => |v| v,
                else => return false,
            };
            if (dslot != a) { return false; }
            const sty = self.air.typeOf(st.rhs, &self.zcu.intern_pool);
            const sw = self.storageBytes(sty, "写回宽度") catch return false;
            if (sw != n) { return false; }
            return true;
        }
        // ② 操作数本身就是临时槽（SSA 语义成立）：沿用「定义在本块 + 全函数无人再读」。
        const ti = lhs.toIndex() orelse return false;
        var defined_here = false;
        for (body[0..idx]) |ins| {
            if (@backingInt(ins) == @backingInt(ti)) {
                defined_here = true;
                break;
            }
        }
        if (!defined_here) return false;
        return self.useCountWholeAir(ti, body[idx]) == 0;
    }

    /// 这条指令的值在全函数里最后一次被读的位置（下标）；没人读返回 0。
    fn airLastRead(self: *Lower, target: Air.Inst.Index) usize {
        var last: usize = 0;
        var i: usize = 0;
        while (i < self.air.instructions.len) : (i += 1) {
            const ins: Air.Inst.Index = @enumFromInt(i);
            if (@backingInt(ins) == @backingInt(target)) continue;
            if (self.instUsesValue(ins, target)) last = i;
        }
        return last;
    }

    /// 分配一段「到期自动回收」的 scratch（宽结果用）。到期 = 最后读取点已过。
    fn allocScratch(self: *Lower, n: u8, owner: Air.Inst.Index) !u8 {
        const base = try self.allocSlots(n, false);
        var i: u8 = 0;
        while (i < n) : (i += 1) self.wide_blk[base + i] = true;
        if (self.scratch_n < self.scratch_runs.len) {
            self.scratch_runs[self.scratch_n] = .{
                .base = base,
                .n = n,
                .last = self.airLastRead(owner),
                .body = @intFromPtr(self.cur_body.ptr),
            };
            self.scratch_n += 1;
        }
        return base;
    }

    /// 回收所有「最后读取点已经过去」的 scratch。
    /// `cur` 是**当前 AIR 指令**（不是 body 下标）；只有同一 body 内才比。
    fn freeDeadScratch(self: *Lower, cur: Air.Inst.Index) void {
        const cur_id: usize = @backingInt(cur);
        const cur_body: usize = @intFromPtr(self.cur_body.ptr);
        var w: u8 = 0;
        var i: u8 = 0;
        while (i < self.scratch_n) : (i += 1) {
            const r = self.scratch_runs[i];
            if (r.body != cur_body or r.last >= cur_id) {
                self.scratch_runs[w] = r;
                w += 1;
                continue;
            }
            var k: u8 = 0;
            while (k < r.n) : (k += 1) {
                self.slot_used[@intCast(@as(u16, r.base) + k)] = false;
                self.wide_blk[@intCast(@as(u16, r.base) + k)] = false;
            }
        }
        self.scratch_n = w;
    }

    /// body 退出时回收它内部创建的所有 scratch：嵌套块展开完就该还槽，
    /// 否则这些槽会跟着外层函数一直占着（DSEG 只有 80 字节）。
    fn freeScratchOfBody(self: *Lower, body: []const Air.Inst.Index) void {
        const id = @intFromPtr(body.ptr);
        var w: u8 = 0;
        var i: u8 = 0;
        while (i < self.scratch_n) : (i += 1) {
            const r = self.scratch_runs[i];
            if (r.body != id) {
                self.scratch_runs[w] = r;
                w += 1;
                continue;
            }
            var k: u8 = 0;
            while (k < r.n) : (k += 1) {
                self.slot_used[@intCast(@as(u16, r.base) + k)] = false;
                self.wide_blk[@intCast(@as(u16, r.base) + k)] = false;
            }
        }
        self.scratch_n = w;
    }

    /// 该宽操作数是不是**直接别名到存储**（变量槽/固定地址），而不是一份临时拷贝。
    /// wideOperand 在 width 正好相等时直接返回原槽 ⇒ 原地写回会踩掉变量本身。
    /// 本条指令的结果是否**只被下一条指令只读消费**（cmp / 作加减法的右操作数 / 写存储的值）。
    /// 只有这些形态才允许把结果分到临时槽：它们读一次就走，不会被写回去。
    /// `load`、未知消费者一律不放行（可能把结果当自己的落点，临时槽会被提前复用）。
    /// 本条指令的结果是否**所有消费者都只读**（cmp / 加减法右操作数 / 乘除任一侧 / store 值 / 实参 / 返回值）。
    /// 只读消费者读一次就走、不会把结果当落点，所以结果可以放 scratch（最后读取点后自动还池）。
    /// 注意要看**全函数所有使用者**：只看下一条会漏掉「先算两个、再一起用」的形态（hypot 就是）。
    fn scratchConsumerOk(self: *Lower, body: []const Air.Inst.Index, idx: usize) bool {
        const cur = body[idx];
        var uses: usize = 0;
        var i: usize = 0;
        while (i < self.air.instructions.len) : (i += 1) {
            const ins: Air.Inst.Index = @enumFromInt(i);
            if (@backingInt(ins) == @backingInt(cur)) continue;
            if (!self.instUsesValue(ins, cur)) continue;
            uses += 1;
            if (!self.isReadOnlyUse(ins, cur)) return false;
        }
        return uses > 0;
    }

    /// 单条指令对某个值的用法是不是「只读」。
    fn isReadOnlyUse(self: *Lower, ins: Air.Inst.Index, target: Air.Inst.Index) bool {
        const tag = self.air.instructions.items(.tag)[@backingInt(ins)];
        const d = self.air.instructions.items(.data)[@backingInt(ins)];
        const t = @backingInt(target);
        switch (tag) {
            .cmp_lt, .cmp_lte, .cmp_gt, .cmp_gte, .cmp_eq, .cmp_neq => {
                if (d.bin_op.lhs.toIndex()) |x| if (@backingInt(x) == t) return true;
                if (d.bin_op.rhs.toIndex()) |x| if (@backingInt(x) == t) return true;
            },
            .mul, .mul_safe, .mul_wrap, .div_trunc, .rem => {
                if (d.bin_op.lhs.toIndex()) |x| if (@backingInt(x) == t) return true;
                if (d.bin_op.rhs.toIndex()) |x| if (@backingInt(x) == t) return true;
            },
            .add, .add_safe, .add_wrap, .sub, .sub_safe, .sub_wrap => {
                if (d.bin_op.rhs.toIndex()) |x| if (@backingInt(x) == t) return true;
            },
            .store, .store_safe => {
                if (d.bin_op.rhs.toIndex()) |x| if (@backingInt(x) == t) return true;
            },
            .ret, .ret_safe => {
                if (d.un_op.toIndex()) |x| if (@backingInt(x) == t) return true;
            },
            .call, .call_always_tail, .call_never_tail, .call_never_inline => {
                const ci = self.air.unwrapCall(ins);
                for (ci.args) |a| {
                    if (a.toIndex()) |x| {
                        if (@backingInt(x) == t) return true;
                    }
                }
            },
            else => {},
        }
        return false;
    }

    /// 局部量的地址有没有逃逸：只被 load/store 直接读写就算没逃逸（保守版：
    /// 取元素地址、传参、返回都判逃逸）。
    /// 函数里有没有取址/元素指针类指令（保守判定用）。

    fn hasAddrTakenOps(self: *Lower) bool {

        var i: usize = 0;

        while (i < self.air.instructions.len) : (i += 1) {

            const ins: Air.Inst.Index = @enumFromInt(i);
            const tag = self.air.instructions.items(.tag)[@backingInt(ins)];

            switch (tag) {

                .ptr_elem_ptr => return true,

                else => {},

            }

        }

        return false;

    }

    fn allocConfined(self: *Lower, target: Air.Inst.Index) bool {
        const t = @backingInt(target);
        var i: usize = 0;
        while (i < self.air.instructions.len) : (i += 1) {
            const ins: Air.Inst.Index = @enumFromInt(i);
            if (@backingInt(ins) == t) continue;
            const tag = self.air.instructions.items(.tag)[@backingInt(ins)];
            const d = self.air.instructions.items(.data)[@backingInt(ins)];
            if (tag == .load) {
                if (d.ty_op.operand.toIndex()) |x| if (@backingInt(x) == t) continue;
            }
            if (tag == .store or tag == .store_safe) {
                if (d.bin_op.lhs.toIndex()) |x| if (@backingInt(x) == t) continue;
            }
            if (self.instUsesValue(ins, target)) return false;
        }
        return true;
    }
    fn wideIsAlias(self: *Lower, ref: Air.Inst.Ref, n: u8) bool {
        if (self.wideOf(ref)) |w| {
            const wn: u8 = @truncate(w >> 8);
            return wn == n;
        }
        return false;
    }

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

    /// 类型名（只覆盖后端认得的形态）：把改写建议里的签名写实。
    fn typeName(self: *Lower, ty: Type) []const u8 {
        return switch (ty.zigTypeTag(self.zcu)) {
            .int => blk: {
                const ii = self.intInfo(ty) orelse break :blk "usize";
                break :blk switch (ii.bytes) {
                    1 => if (ii.signed) "i8" else "u8",
                    2 => if (ii.signed) "i16" else "u16",
                    4 => if (ii.signed) "i32" else "u32",
                    else => "usize",
                };
            },
            .bool => "bool",
            .pointer => "*u8",
            .void => "void",
            else => "usize",
        };
    }

    /// 带「可直接粘贴的 Zig 改写代码」的拒绝：错误里用真实函数名、形参类型与返回类型。
    fn failFix(self: *Lower, kind: diag.Kind, comptime fmt: []const u8, args: anytype) codegen.Error {
        return self.failFixCtx(kind, null, fmt, args);
    }

    /// 带 AIR 现场信息的版本：`extra` 里的源码片段会写进改写建议。
    fn failFixCtx(
        self: *Lower,
        kind: diag.Kind,
        extra: ?diag.Extra,
        comptime fmt: []const u8,
        args: anytype,
    ) codegen.Error {
        const ip = &self.zcu.intern_pool;
        const ft = ip.indexToKey(self.fn_ty.toIntern()).func_type;
        const pts = ft.param_types.get(ip);
        const names = self.gpa.alloc([]const u8, pts.len) catch return error.OutOfMemory;
        defer self.gpa.free(names);
        for (pts, 0..) |pi, i| names[i] = self.typeName(Type.fromInterned(pi));

        // 尽量用源码里的真实参数名（n / m），拿不到才退回 a0 / a1。
        const pnames: ?[]const []const u8 = self.param_names;

        const fix = diag.render(self.gpa, kind, self.short_name, names, pnames,
            self.typeName(self.fn_ty.fnReturnType(self.zcu)), extra) catch return error.OutOfMemory;
        defer self.gpa.free(fix);
        const head = std.fmt.allocPrint(self.gpa, "mcs2: " ++ fmt, args) catch return error.OutOfMemory;
        defer self.gpa.free(head);
        const full = std.fmt.allocPrint(self.gpa, "{s}\n\n{s}", .{ head, fix }) catch return error.OutOfMemory;
        defer self.gpa.free(full);
        return self.zcu.codegenFail(self.nav, "{s}", .{full});
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
            // 溢出检查也引用标签：漏了这两条会把停机尾块当死代码删掉。
            .bit_br => |x| if (x.target == id) return true,
            .br_c => |x| if (x.target == id) return true,
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

    /// 溢出检查的目标标签：懒分配，走模块级临时标签域（跨函数不撞号）。
    fn panicTarget(self: *Lower) u32 {
        if (self.panic_label) |l| return l;
        const l = self.tempLabel();
        self.panic_label = l;
        return l;
    }

    /// 发一条溢出检查：无符号看进位 C（PSW.7 = 0xD7），有符号看溢出 OV
    /// （PSW.2 = 0xD2）。标志必须紧贴算术指令之后有效，所以调用点要避开
    /// `inc/dec` 那条不改标志的发射捷径（见 8 位加减分支）。
    fn trapTarget(self: *Lower) u32 {
        if (self.trap_label) |l| return l;
        const l = self.tempLabel();
        self.trap_label = l;
        return l;
    }

    /// 停机块：先往诊断槽写一个标记（溢出 0x5A、越界 0xA5），再 `sjmp .`。
    /// 地址取 xdata 0x8100，避开验收用的 0x8000 结果槽；尺寸档不生成这块代码。
    fn appendPanicBlock(self: *Lower, gpa: std.mem.Allocator, label: u32, mark: u8) codegen.Error!void {
        try self.ops.appendSlice(gpa, &.{
            .{ .label = label },
            .{ .imm = .{ .dst = .{ .dir = 0xE0 }, .value = mark } },
            .{ .store_xdata = .{ .addr = 0x8100, .src = .{ .dir = 0xE0 } } },
            .halt,
        });
    }

    fn emitOverflowCheck(self: *Lower, signed: bool) codegen.Error!void {
        try self.ops.append(self.gpa, .{ .bit_br = .{
            .bit = if (signed) 0xD2 else 0xD7,
            .target = self.panicTarget(),
            .on_set = true,
        } });
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
        if (n != 1) return self.failFix(.switch_wide, "switch 的判定值暂时只支持 8 位（u8 / ≤256 的 enum）", .{});
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



    /// 这条 AIR 是否读取 target。供局部优化与全函数死亡判定共用。
    fn instUsesValue(self: *Lower, ins: Air.Inst.Index, target: Air.Inst.Index) bool {
        const tag = self.air.instructions.items(.tag)[@backingInt(ins)];
        const d = self.air.instructions.items(.data)[@backingInt(ins)];
        switch (tag) {
            // 二元操作：**所有** bin_op 形态都要算进来。
            // 早期只列了 add/sub/cmp，漏掉 shr/mul/bit_and ... 会让 useCountWholeAir
            // 误判「值已死」，原地写回提前覆盖源槽（sqrt32 的 res >> 1 就是这么错的）。
            .add, .add_safe, .add_wrap, .sub, .sub_safe, .sub_wrap,
            .mul, .mul_safe, .mul_wrap, .div_trunc, .rem,
            .bit_and, .bit_or, .xor, .shl, .shr, .shl_exact, .shr_exact,
            .store, .store_safe,
            .cmp_lt, .cmp_lte, .cmp_gt, .cmp_gte, .cmp_eq, .cmp_neq,
            => {
                if (d.bin_op.lhs.toIndex()) |x| {
                    if (@backingInt(x) == @backingInt(target)) return true;
                }
                if (d.bin_op.rhs.toIndex()) |x| {
                    if (@backingInt(x) == @backingInt(target)) return true;
                }
            },
            // 单操作数消费者：比较结果被 return / 转换 / 取反直接吃掉时也算「当值用」。
            .ret, .ret_safe => {
                if (d.un_op.toIndex()) |x| {
                    if (@backingInt(x) == @backingInt(target)) return true;
                }
            },
            // 带返回值块通过 br 把值写入内存 phi；漏算就会提前覆盖源槽。
            .br => {
                if (d.br.operand.toIndex()) |x| {
                    if (@backingInt(x) == @backingInt(target)) return true;
                }
            },
            // 调用实参/被调方也是使用者：漏了会让 airLastRead 返回 0，
            // 既误判「值已死」，也错过「实参是只读消费者」的 scratch 机会。
            .call, .call_always_tail, .call_never_tail, .call_never_inline => {
                const ci = self.air.unwrapCall(ins);
                if (ci.callee.toIndex()) |x| {
                    if (@backingInt(x) == @backingInt(target)) return true;
                }
                for (ci.args) |a| {
                    if (a.toIndex()) |x| {
                        if (@backingInt(x) == @backingInt(target)) return true;
                    }
                }
            },
            // `.load` 的 operand 就是局部量的 `.alloc` 结果；漏了它，宽局部量
            // 的最后读取点会被算成 0，scratch 一回收就把变量槽让给别人。
            .int_cast, .int_cast_safe, .trunc, .not, .bit_cast, .load => {
                if (d.ty_op.operand.toIndex()) |x| {
                    if (@backingInt(x) == @backingInt(target)) return true;
                }
            },
            else => {},
        }
        return false;
    }

    /// P1：数一数某条指令的值在 body 里被用了几次（跳过 skip 位置）。
    fn useCount(self: *Lower, body: []const Air.Inst.Index, target: Air.Inst.Index, skip: usize) usize {
        var n: usize = 0;
        for (body, 0..) |ins, k| {
            if (k != skip and self.instUsesValue(ins, target)) n += 1;
        }
        return n;
    }

    /// 原地写回专用：跨块引用也算存活，skip 是要排除的当前指令。
    fn useCountWholeAir(self: *Lower, target: Air.Inst.Index, skip: Air.Inst.Index) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.air.instructions.len) : (i += 1) {
            const ins: Air.Inst.Index = @enumFromInt(i);
            if (@backingInt(ins) == @backingInt(skip)) continue;
            if (self.instUsesValue(ins, target)) n += 1;
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

    /// 宽块在 MIR 里只保存首槽号；重命名时必须移动整个基址，不能只映射其中的临时字节。
    fn mapWideVreg(v: u8, map: *const [256]?u8) u8 {
        return map[v] orelse v;
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
            .clr_c, .ljmp => op,
            .load_xdata_dptr => |x| .{ .load_xdata_dptr = .{ .dst = mapByteVreg(x.dst, map) } },
            .dptr_add_scaled => |x| .{ .dptr_add_scaled = .{ .idx = mapByteVreg(x.idx, map), .scale = x.scale } },
            .store_xdata_dptr => |x| .{ .store_xdata_dptr = .{ .src = mapByteVreg(x.src, map) } },
            .shl => |x| .{ .shl = .{ .dst = mapByteVreg(x.dst, map), .lhs = mapByteVreg(x.lhs, map), .n = x.n } },
            .shr => |x| .{ .shr = .{ .dst = mapByteVreg(x.dst, map), .lhs = mapByteVreg(x.lhs, map), .n = x.n, .arith = x.arith } },
            .sex => |x| .{ .sex = .{ .dst = mapByteVreg(x.dst, map), .src = mapByteVreg(x.src, map) } },
            .cmp_wide_br => |x| .{ .cmp_wide_br = .{
                .lhs = mapWideVreg(x.lhs, map),
                .rhs = mapWideVreg(x.rhs, map),
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
            .load_xdata_idx_sym => |x| .{ .load_xdata_idx_sym = .{ .dst = mapByteVreg(x.dst, map), .sym = x.sym, .off = x.off, .idx = mapByteVreg(x.idx, map), .scale = x.scale } },
            .store_xdata_idx_sym => |x| .{ .store_xdata_idx_sym = .{ .sym = x.sym, .off = x.off, .idx = mapByteVreg(x.idx, map), .src = mapByteVreg(x.src, map), .scale = x.scale } },
            .load_xdata_sym => |x| .{ .load_xdata_sym = .{ .dst = mapByteVreg(x.dst, map), .sym = x.sym, .off = x.off } },
            .load_code_sym => |x| .{ .load_code_sym = .{ .dst = mapByteVreg(x.dst, map), .sym = x.sym, .off = x.off } },
            .load_code_idx_sym => |x| .{ .load_code_idx_sym = .{ .dst = mapByteVreg(x.dst, map), .sym = x.sym, .off = x.off, .idx = mapByteVreg(x.idx, map), .scale = x.scale } },
            .store_xdata_sym => |x| .{ .store_xdata_sym = .{ .sym = x.sym, .off = x.off, .src = mapByteVreg(x.src, map) } },
            .br_ifnz => |x| .{ .br_ifnz = .{ .cond = mapByteVreg(x.cond, map), .target = x.target } },
            .br_ifz => |x| .{ .br_ifz = .{ .cond = mapByteVreg(x.cond, map), .target = x.target } },
            .cmp_br => |x| .{ .cmp_br = .{ .lhs = mapByteVreg(x.lhs, map), .rhs = mapByteVreg(x.rhs, map), .cc = x.cc, .target = x.target } },
            .dec_br_nz => |x| .{ .dec_br_nz = .{ .dst = mapByteVreg(x.dst, map), .target = x.target } },
            .br_c, .lcall => op,
            .lcall_ind => |x| .{ .lcall_ind = .{
                .target = mapWideVreg(x.target, map),
                .save = mapByteVreg(x.save, map),
            } },
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

        // 多字节块必须整段连着搬。除了仍然存活的 wide_blk，还要从 MIR 恢复
        // 临时宽块的邻接约束：临时槽在每条 AIR 末尾归还时 wide_blk 已清除，
        // 但 cmp_wide_br/lcall_ind 里的基址仍要求原来的若干槽保持连续。
        var wide_join: [255]bool = @splat(false);
        if (nv > 1) {
            var j: usize = 0;
            while (j + 1 < nv) : (j += 1) {
                wide_join[j] = self.wide_blk[j] and self.wide_blk[j + 1];
            }
        }
        for (ops) |op| switch (op) {
            .cmp_wide_br => |x| {
                const width: usize = x.n;
                var k: usize = 0;
                while (k + 1 < width) : (k += 1) {
                    const at: usize = @as(usize, x.lhs) + k;
                    if (at + 1 < nv) wide_join[at] = true;
                    const ar: usize = @as(usize, x.rhs) + k;
                    if (ar + 1 < nv) wide_join[ar] = true;
                }
            },
            .lcall_ind => |x| {
                const at: usize = x.target;
                if (at + 1 < nv) wide_join[at] = true;
            },
            else => {},
        };

        var group_of: [256]u16 = @splat(0xFFFF);
        var group_base: [256]u8 = @splat(0);
        var group_len: [256]u8 = @splat(1);
        var n_groups: usize = 0;
        var v: usize = 0;
        while (v < nv) {
            var len: usize = 1;
            while (v + len < nv and wide_join[v + len - 1]) len += 1;
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
                // 最后读取所在指令执行完后才释放。多字节 MIR 内部可能先写目标、
                // 再继续读源，不能让同一条指令里的“死亡源”和“新生目标”共槽。
                var s: usize = 0;
                while (s < hi) : (s += 1) {
                    if (!slot_free[s] and slot_die[s] < i) slot_free[s] = true;
                }
                // 看看有没有组在这一条 op 上出生
                g = 0;
                while (g < n_groups) : (g += 1) {
                    if (g_def[g] != i) continue;
                    const len = group_len[g];
                    if (g_pin[g]) {
                        // 钉住的组：永远放在当前高水位之上。此前可复用组可能
                        // 已经把 hi 推高，不能仍从旧 pin_hi 分配而覆盖活动槽。
                        if (pin_hi < hi) pin_hi = hi;
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

    fn isWideVreg(base: u8, n: u8, r: u8) bool {
        const begin: u16 = base;
        const at: u16 = r;
        return at >= begin and at < begin + @as(u16, n);
    }

    fn readsVreg(op: mcsmir.Op, r: u8) bool {
        return switch (op) {
            .add => |x| isVregByte(x.lhs, r) or isVregByte(x.rhs, r),
            .sub => |x| isVregByte(x.lhs, r) or isVregByte(x.rhs, r),
            .and_ => |x| isVregByte(x.lhs, r) or isVregByte(x.rhs, r),
            .or_ => |x| isVregByte(x.lhs, r) or isVregByte(x.rhs, r),
            .xor_ => |x| isVregByte(x.lhs, r) or isVregByte(x.rhs, r),
            .mul => |x| isVregByte(x.lhs, r) or isVregByte(x.rhs, r),
            .mul16 => |x| isVregByte(x.lhs, r) or isVregByte(x.rhs, r),
            .div_ => |x| isVregByte(x.lhs, r) or isVregByte(x.rhs, r),
            .rem_ => |x| isVregByte(x.lhs, r) or isVregByte(x.rhs, r),
            .not_ => |x| isVregByte(x.src, r),
            .addc => |x| isVregByte(x.lhs, r) or isVregByte(x.rhs, r),
            .rlc => |x| isVregByte(x.src, r),
            .rrc => |x| isVregByte(x.src, r),
            .subb => |x| isVregByte(x.lhs, r) or isVregByte(x.rhs, r),
            .shl => |x| isVregByte(x.lhs, r),
            .shr => |x| isVregByte(x.lhs, r),
            .sex => |x| isVregByte(x.src, r),
            .mov => |x| isVregByte(x.src, r),
            .cmp_br => |x| isVregByte(x.lhs, r) or isVregByte(x.rhs, r),
            .cmp_wide_br => |x| isWideVreg(x.lhs, x.n, r) or isWideVreg(x.rhs, x.n, r) or isVregByte(x.tmp, r),
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
            .lcall_ind => |x| isWideVreg(x.target, 2, r) or isVregByte(x.save, r),
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
            .cmp_wide_br => |x| isVregByte(x.tmp, r),
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
                .label, .br, .br_ifnz, .br_ifz, .cmp_br, .dec_br_nz, .ret, .reti, .halt,
                // 溢出检查读的是标志位，不能跨它折叠拷贝（会改变 C/OV 的来源）。
                .bit_br, .br_c => true,
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

    /// 自检：op 流里是否有重复定义的标签（改写类优化用来自证没发坏代码）。
    fn hasDupLabels(self: *Lower) bool {
        var seen = std.AutoHashMap(u32, void).init(self.gpa);
        defer seen.deinit();
        for (self.ops.items) |op| switch (op) {
            .label => |l| {
                if (seen.contains(l)) return true;
                seen.put(l, {}) catch return false;
            },
            else => {},
        };
        return false;
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
                    // 有符号 x < 0 / x >= 0：直接测最高字节的符号位（抄 SDCC 的 jnb acc.7）。
                    // 省掉「把常量 0 物化成一整块 + 跑完整借位链」，absU 的 cmp 槽就是这么多的。
                    const rhs_zero = if (self.constWide(bin.rhs)) |v| v == 0 else false;
                    const is_lt = tg == .cmp_lt or tg == .cmp_lt_optimized;
                    const is_gte = tg == .cmp_gte or tg == .cmp_gte_optimized;
                    if (oi.signed and rhs_zero and (is_lt or is_gte)) {
                        const lhs = try self.wideOperand(bin.lhs, oi.bytes);
                        const tmp = try self.allocVreg();
                        try self.movTo(tmp, mcsmir.v(lhs + oi.bytes - 1));
                        try self.ops.append(self.gpa, .{ .clr_c = {} });
                        try self.ops.append(self.gpa, .{ .rlc = .{ .dst = mcsmir.v(tmp), .src = mcsmir.v(tmp) } });
                        // 条件不成立 → else：lt 时"C==0 即非负"；gte 时"C==1 即负"。
                        try self.ops.append(self.gpa, .{ .br_c = .{ .target = else_lbl, .on_set = !is_lt } });
                        fused = true;
                    } else {
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
                    }
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
    // scratch 的生命周期按 body 分区：进来记录、退出整段回收，嵌套块的槽
    // 不会跟着外层函数一直占着。
    const prev_body = self.cur_body;
    self.cur_body = body;
    defer {
        self.freeScratchOfBody(body);
        self.cur_body = prev_body;
    }
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
        self.cur_inst = inst;
        self.cur_scratch_ok = switch (self.air.instructions.items(.tag)[@backingInt(inst)]) {
            .add, .add_safe, .add_wrap, .sub, .sub_safe, .sub_wrap,
            .mul, .mul_safe, .mul_wrap, .div_trunc, .rem, .bit_and, .bit_or, .xor,
            .shl, .shr, .shl_exact, .shr_exact, .not,
            // 转换**结果**也可以 scratch：转换若分配新块，那它是全新的；只要它的消费者都只读
            // （典型是 ret），这块就可以在最后读取点之后还池。恒等转换本来就不分配，走不到这里。
            .int_cast, .int_cast_safe, .trunc, .bit_cast,
            => self.scratchConsumerOk(body, idx),
            .call, .call_always_tail, .call_never_tail, .call_never_inline,
            => self.scratchConsumerOk(body, idx),
            else => false,
        };
        self.freeDeadScratch(inst);
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
                const is_ptr = ty.zigTypeTag(self.zcu) == .pointer;
                if (self.wideBytes(ty) == null and ty.zigTypeTag(self.zcu) != .bool and !is_ptr) {
                    return self.zcu.codegenFail(
                        self.nav,
                        "mcs2: 参数类型 {s} 尚未实现（目前只支持 8/16/32 位整数、bool 与指针）",
                        .{@tagName(ty.zigTypeTag(self.zcu))},
                    );
                }
                // SDCC mcs51 实测约定（--model-small）：**第 1 个参数**按低字节序进
                // DPL/DPH/B/A（最多 4 字节），**第 2 个起**进 `_名_PARM_2` 起的连续字节。
                // 对齐它 = u16/u32 的 C 互操作免费，不需要 thunk。
                // ADR-001 边界 ABI：按**字节**摆放（arg0 → DPL，之后 → PARM_n）；
                // u16 占两个字节（DPL/DPH 或 PARM_n/PARM_{n+1}）。
                const nlat: u8 = if (is_ptr) 2 else (self.wideBytes(ty) orelse 1);
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
                    // 指针参数：记成「运行期 16 位基址」，后面 p[i] 直接从这里取。
                    if (is_ptr) self.ptr_vals[@backingInt(inst)] = .{ .rt = .{
                        .lo = mcsmir.v(base),
                        .hi = mcsmir.v(base + 1),
                    } };
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
                    // 元素**步长** = 结果指针所指类型的完整大小：
                    //   `T16[i]`（lhs 是 *[8]u16，结果 *u16）→ 2
                    //   `fb[z]` （lhs 是 *[32][64]u16，结果 *[32][64]u16）→ 32*64*2 = 4096
                    // 旧写法把子数组剥到最内层元素（→2），多维下标就会指错地方。
                    const pty = self.air.typeOfIndex(inst, &self.zcu.intern_pool);
                    const sc = try self.pointeeBytes(pty.childType(self.zcu), "下标元素");
                    if (self.dump_air) std.debug.print("  >> elem stride={d} res={s}\n", .{
                        sc,
                        @tagName(pty.zigTypeTag(self.zcu)),
                    });
                    // 常量下标优先折叠：地址直接落成常量 / 符号+偏移（省掉整条加法序列）。
                    if (self.constU8(bin.rhs)) |k| {
                        const fld = @as(u64, k) * sc;
                        switch (pr) {
                            .fixed => |b| {
                                self.ptr_vals[@backingInt(inst)] = .{ .fixed = b + fld };
                                continue;
                            },
                            .sym_off => |s| {
                                self.ptr_vals[@backingInt(inst)] = .{ .sym_off = .{ .sym = s.sym, .off = s.off + fld } };
                                continue;
                            },
                            .code_sym => |s| {
                                self.ptr_vals[@backingInt(inst)] = .{ .code_sym = .{ .sym = s.sym, .off = s.off + fld } };
                                continue;
                            },
                            .rt => |r| {
                                self.ptr_vals[@backingInt(inst)] = .{ .rt = .{ .lo = r.lo, .hi = r.hi, .off = r.off + fld } };
                                continue;
                            },
                            else => {},
                        }
                    }
                    // 其余情况：基址 + 一维下标（第二次下标起升级成多维链）
                    const idx_slot = try self.indexLoc(bin.rhs);
                    self.ptr_vals[@backingInt(inst)] = try self.indexedRef(pr, idx_slot.lo, idx_slot.hi, sc);
                }
            },

            .add, .add_safe, .add_wrap, .sub, .sub_safe, .sub_wrap => {
                const bin = data.bin_op;
                const ty = self.air.typeOfIndex(inst, &self.zcu.intern_pool);
                const wi = try self.requireIntWidth(ty, "加减法");
                const n = wi.bytes;
                // 安全档：Sema 发 `_safe` 标签（ReleaseSafe），溢出必须停机而不是回绕。
                const checked = tag == .add_safe or tag == .sub_safe;
                // 多字节：固定模板 = clr c + addc/subb 逐字节（低字节在前）。
                if (n > 1) {
                    // ① 0 - x 直接走二补码取负：省掉「把常量 0 物化成 n 个槽」。
                    // absU（if (v < 0) return -v）这类形态原来光零常量就占 4 槽。
                    // 安全档不走这条捷径：取负不发进位链，没有可用的溢出标志。
                    const is_sub_tag = tag == .sub or tag == .sub_safe or tag == .sub_wrap;
                    if (is_sub_tag and !checked) {
                        if (self.constWide(bin.lhs)) |lv| {
                            if (lv == 0) {
                                const bneg = try self.wideOperand(bin.rhs, n);
                                const dneg = if (self.reuseWideDst(body, idx, bin.rhs, bneg, n)) bneg else try self.allocWide(n);
                                try self.negInto(dneg, bneg, n);
                                self.vals[@backingInt(inst)] = mcsmir.v(dneg);
                                self.wide[@backingInt(inst)] = @as(u16, dneg) | (@as(u16, n) << 8);
                                continue;
                            }
                        }
                    }
                    const a = try self.wideOperand(bin.lhs, n);
                    const b = try self.wideOperand(bin.rhs, n);
                    const reuse_n = (self.reuseWideDst(body, idx, bin.lhs, a, n) and !(forbid_alias_reuse and self.wideIsAlias(bin.lhs, n)));
                    const scratch_n = scratch_results and self.scratchConsumerOk(body, idx);
                    const d = if (reuse_n) a else if (scratch_n) try self.allocScratch(n, inst) else try self.allocWide(n);
                    if (account_wide and !reuse_n) std.debug.print("WIDE inst={d} base={d} n={d} last={d} scratch={}\n", .{ @backingInt(inst), d, n, self.airLastRead(inst), scratch_n });
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
                    // 链尾最后一条 addc/subb 的 C（无符号）或 OV（有符号）就是整块的
                    // 溢出标志；发射层里的 mov dst,a 不动标志。
                    if (checked) try self.emitOverflowCheck(wi.signed);
                    continue;
                }
                const lhs = try self.refLoc(bin.lhs);
                const rhs = try self.refLoc(bin.rhs);
                // 「ret 前看一眼」：下一非调试指令若是 ret 且操作数是本指令，
                // 结果直接写 DPL（扩展访问优化的最小版：省一次 vreg 往返）。
                var consumed_by_ret = false;
                // 安全档禁用「结果直写返回寄存器」：那会让 dst 与 lhs 同址，
                // 发射层改发 inc/dec 而**不动标志位**，溢出检查就会读到旧 C/OV。
                if (!checked and self.ret_byte != null and idx + 1 < body.len) {
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
                if (!consumed_by_ret and !checked) {
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
                // dst 是新槽（!= lhs），发射层走 add/subb 而非 inc/dec，C/OV 有效。
                if (checked) try self.emitOverflowCheck(wi.signed);
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
                    const reuse_o = (self.reuseWideDst(body, idx, bin.lhs, a, n) and !(forbid_alias_reuse and self.wideIsAlias(bin.lhs, n)));
        const d = if (reuse_o) a else try self.allocWide(n);
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
            .mul, .mul_safe, .mul_wrap, .div_trunc, .rem, .not => {
                const ty = self.air.typeOfIndex(inst, &self.zcu.intern_pool);
                const info = try self.requireIntWidth(ty, "乘除/取反");
                // 安全档乘法：8 位无符号能靠 MUL AB 的高半（B）判溢出；多字节/有符号
                // 走的是移位加法模板，没有现成溢出标志。宁可明确报错也不静默回绕——
                // 需要回绕语义请写 `*%`（详见改写建议）。
                if (tag == .mul_safe and (info.bytes > 1 or info.signed)) {
                    return self.failFix(.mul_safe, "ReleaseSafe 的多字节/有符号乘法溢出检查尚未实现", .{});
                }
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
                // MUL AB 之后 B 就是积的高字节，非零即 8 位无符号溢出。
                // 必须放在恢复 arg2 的 B 之前——那一步会把高字节盖掉。
                if (tag == .mul_safe) {
                    try self.ops.append(self.gpa, .{ .cmp_br = .{
                        .lhs = .{ .dir = 0xF0 },
                        .rhs = .{ .imm = 0 },
                        .cc = .ne,
                        .target = self.panicTarget(),
                    } });
                }
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
                const reuse_s = (self.reuseWideDst(body, idx, bin.lhs, a, nw) and !(forbid_alias_reuse and self.wideIsAlias(bin.lhs, nw)));
                const d = if (reuse_s) a else try self.allocWide(nw);
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

            // 指针类型转换（`[*]u8` → `*[8]u8` 之类）：位模式不变，2 字节原样透传，
            // 并把「运行期基址」信息带过去（否则后面 p[i] 就找不到基址了）。
            .ptr_cast => {
                const base = try self.wideOperand(data.ty_op.operand, 2);
                self.vals[@backingInt(inst)] = mcsmir.v(base);
                self.wide[@backingInt(inst)] = @as(u16, base) | (@as(u16, 2) << 8);
                if (self.ptrRefOf(data.ty_op.operand)) |pr| switch (pr) {
                    // 运行期基址跟着**新槽**走（旧槽可能已经被当临时槽回收）
                    .rt, .rt_elem => self.ptr_vals[@backingInt(inst)] = .{ .rt = .{
                        .lo = mcsmir.v(base),
                        .hi = mcsmir.v(base + 1),
                    } },
                    else => self.ptr_vals[@backingInt(inst)] = pr,
                };
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
                    return self.failFix(.data_addr, "只支持把函数地址转成整数（数据指针的地址暂不支持）", .{});
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
                if (alloc_report) std.debug.print("ALLOC fn={s} inst={d} n={d} confined={}\n", .{ self.short_name, @backingInt(inst), n, self.allocConfined(inst) });
                // 保守：函数里只要出现取址/元素指针指令，就认为局部量可能被外部持有，
                // 一律给永久槽（pprt/pu16/wloc2 就是这么被提前复用踩坏的）。
                const confined = self.allocConfined(inst) and !self.hasAddrTakenOps();
                // 地址没逃逸的局部量就是一个 SSA 值：按 AIR 最后读取点回收，不必占永久槽。
                // 只对**单字节**局部量开这条路。宽值（n>1）试过三次：补 `.load` 引用、
                // 统一回收尺度、按引用所在块收敛，均让 `wloc2` 的高字节被提前回收的槽踩掉。
                // 根因是「全 AIR 下标 / body 下标」两套生命周期尺度混用，需要真正的
                // 活跃期分析重做，不能靠加判据修。宽局部量继续用永久槽。
                const base = if (confined and scratch_results and n == 1)
                    try self.allocScratch(n, inst)
                else
                    try self.allocWide(n);
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
                        if (dbase + k2 != sbase + k2)
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
                const idx_slot = try self.indexLoc(bin.rhs);
                // 步长 = 基址指针所指整块的大小（多维时就是子数组大小，不是元素宽）
                const lhs_ty = self.air.typeOf(bin.lhs, &self.zcu.intern_pool);
                const stride: u32 = if (lhs_ty.zigTypeTag(self.zcu) == .pointer)
                    try self.pointeeBytes(lhs_ty.childType(self.zcu), "下标步长")
                else
                    n;
                if (stride == 0) return self.fail("下标步长为 0", .{});
                const indexed: PtrRef = try self.indexedRef(pr, idx_slot.lo, idx_slot.hi, stride);
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
                    if (lty.zigTypeTag(self.zcu) == .pointer) self.ptr_vals[@backingInt(inst)] = .{ .rt = .{
                        .lo = mcsmir.v(wb),
                        .hi = mcsmir.v(wb + 1),
                    } };
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
                    // 指针值（`p` 从参数槽搬回局部槽时走这条）：记成运行期基址
                    if (lty.zigTypeTag(self.zcu) == .pointer) self.ptr_vals[@backingInt(inst)] = .{ .rt = .{
                        .lo = mcsmir.v(base),
                        .hi = mcsmir.v(base + 1),
                    } };
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
                // 尾调用已经 ljmp 走了：这条 ret 是死代码，别再发 ret（否则会多弹一次栈）。
                if (self.tail_ret) |tr| if (tr == inst) {
                    self.tail_ret = null;
                    self.saw_ret = true;
                    return true;
                };
                if (self.is_isr) {
                    // ISR 尾声：恢复现场（逆序）+ reti。诊断开关同序言。
                    const no_save = no_isr_save;
                    if (!no_save) {
                        try self.ops.appendSlice(self.gpa, &.{
                            .{ .pop = .{ .dst = .{ .dir = 0xF0 } } }, // B
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
                    if (total > 4) return self.failFix(
                        .ind_call_args,
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
                // 被调函数的 nav：用来识别直接自递归（非尾时静态槽不可重入）。
                var callee_nav: ?InternPool.Nav.Index = null;
                // 取函数地址再调用（callee 是 .ptr 指向具名函数）→ 解出符号走直调，
                // 比物化 2 字节地址再间接调更省。
                var resolved = false;
                if (key == .ptr) {
                    const nav = switch (key.ptr.base_addr) {
                        .nav => |n| n,
                        else => return self.fail("取地址调用的目标不是具名函数", .{}),
                    };
                    callee_nav = nav;
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
                            callee_nav = nav;
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
                // 常量实参不用物化成槽：直接按字节写进 ABI 位置（省 n 个槽）。
                const consts = try self.gpa.alloc(?u32, nargs);
                defer self.gpa.free(consts);
                for (ci.args, 0..) |arg_ref, ai| {
                    const aty = self.air.typeOf(arg_ref, ip);
                    const an = try self.storageBytes(aty, "调用参数");
                    if (an > 4) return self.failFix(.param_over4, "参数超过 4 字节（多字节结构体）尚未支持", .{});
                    widths[ai] = an;
                    consts[ai] = self.constWide(arg_ref);
                    bases[ai] = if (consts[ai] != null) 0 else try self.wideOperand(arg_ref, an);
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
                        if (consts[ai]) |cv| {
                            const byte: u8 = @truncate(cv >> @intCast(8 * @as(u32, k)));
                            try self.ops.append(self.gpa, .{ .imm = .{ .dst = dst, .value = byte } });
                        } else {
                            try self.ops.append(self.gpa, .{ .mov = .{ .dst = dst, .src = mcsmir.v(base + k) } });
                        }
                    }
                    if (ai > 0) spill += an;
                }
                // **尾调用**：调用结果被紧接的 ret 原样返回 → 参数摆好后直接 ljmp，
                // 不再压返回地址。8051 没有栈帧，被调方的 ret 直接回到**我们的**调用方；
                // 自递归因此变成循环（栈深度不再增长）。ISR 里禁用：必须以 reti 收尾。
                if (!self.is_isr) {
                    if (self.tailRetOf(body, idx, inst, ret_n > 0)) |ri| {
                        try self.ops.append(self.gpa, .{ .ljmp = .{ .sym = sym } });
                        self.tail_ret = ri;
                        self.saw_ret = true;
                        continue;
                    }
                }
                // 非尾直接递归：参数区与局部槽都是静态分配，内层调用会覆盖外层，
                // 结果错却不报错。尾递归上面已转成 ljmp（等价于循环），只拒绝非尾形态。
                if (callee_nav) |cn| {
                    if (cn == self.nav) {
                        // M1：从 AIR 还原真实写法（`return f(n-1) * 2`），让建议
                        // 里的累加器版本带真实实参与真实运算，而不是全占位符。
                        var arena = std.heap.ArenaAllocator.init(self.gpa);
                        defer arena.deinit();
                        const extra = self.renderNontailExtra(arena.allocator(), inst) catch null;
                        return self.failFixCtx(
                            .tail_rec,
                            extra,
                            "非尾递归不受支持（静态参数区与局部槽不可重入）",
                            .{},
                        );
                    }
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
                        // 有符号 x < 0 / x >= 0：只看最高字节的符号位，不需要把常量 0
                        // 物化成一整块再去跑 4 字节比较（absU 的 4 个 cmp 槽就是这么来的）。
                        // 这是从 SDCC 的 jnb acc.7 抄来的。
                        const rhs_zero = if (self.constWide(bin.rhs)) |v| v == 0 else false;
                        const is_lt = tag == .cmp_lt or tag == .cmp_lt_optimized;
                        const is_gte = tag == .cmp_gte or tag == .cmp_gte_optimized;
                        if (oi.signed and rhs_zero and (is_lt or is_gte)) {
                            const lhs = try self.wideOperand(bin.lhs, oi.bytes);
                            const tmp = try self.allocVreg();
                            try self.movTo(tmp, mcsmir.v(lhs + oi.bytes - 1));
                            try self.ops.append(self.gpa, .{ .clr_c = {} });
                            try self.ops.append(self.gpa, .{ .rlc = .{ .dst = mcsmir.v(tmp), .src = mcsmir.v(tmp) } });
                            const l_skip = self.tempLabel();
                            // lt：C=1（负）时写 1；gte：C=0 时写 1。跳到 l_skip 表示保持 0。
                            try self.ops.append(self.gpa, .{ .br_c = .{ .target = l_skip, .on_set = !is_lt } });
                            try self.ops.append(self.gpa, .{ .imm = .{ .dst = d, .value = 1 } });
                            try self.ops.append(self.gpa, .{ .label = l_skip });
                            self.vals[@backingInt(inst)] = d;
                            continue;
                        }
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

            // 安全档的运行时违规（数组越界、unreachable 等）：前端发 `trap`，
            // 后端跳共享停机块，用与溢出检查不同的标记区分停因。
            .trap => {
                try self.ops.append(self.gpa, .{ .br = self.trapTarget() });
                return true;
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
        .fn_ty = func_ty,
    };
    defer lw.ops.deinit(gpa);
    defer lw.parms.deinit(gpa);
    defer {
        for (lw.sym_pool.items) |s| gpa.free(s);
        lw.sym_pool.deinit(gpa);
    }
    defer lw.const_lines.deinit(gpa);
    defer lw.block_slots.deinit(gpa);

    // 改写建议里要用源码里的真实参数名（n / m），拿不到就退回 a0 / a1。
    {
        const fty = ip.indexToKey(func_ty.toIntern()).func_type;
        const pts = fty.param_types.get(ip);
        if (pts.len > 0) {
            lw.param_names = sourceParamNames(gpa, zcu, func.owner_nav, short_name, pts.len) catch null;
        }
    }
    defer if (lw.param_names) |pn| gpa.free(pn);

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
        // 现场保存：A/PSW/DPTR/**B**。
        // B 也存：mcs2 用到 B —— arg0 的第 3 字节、MUL/DIV 的结果高半、间接调用。
        // 早期注释写「B 未用」是错的：ISR 里只要出现一次 16 位乘除（或调用会乘除的函数），
        // 被打断的主程序 B 就被踩坏（主程序若正拿 B 当 arg2 / 乘法高位，回来就错）。
        // 注意顺序与尾声严格相反。诊断开关 MCS2_NO_ISR_SAVE=1 可跳过。
        try lw.ops.appendSlice(gpa, &.{
            .{ .push = .{ .src = .{ .dir = 0xE0 } } }, // ACC
            .{ .push = .{ .src = .{ .dir = 0xD0 } } }, // PSW
            .{ .push = .{ .src = .{ .dir = 0x82 } } }, // DPL
            .{ .push = .{ .src = .{ .dir = 0x83 } } }, // DPH
            .{ .push = .{ .src = .{ .dir = 0xF0 } } }, // B
        });
    }

    const body_terminated = try lw.emitBody(body);

    // 安全档：把共享停机块接在函数体之后。停机前往 xdata 0x8100 写诊断标记
    // （溢出 0x5A / 越界 0xA5），再 `sjmp .`；freestanding 上没有可调用的 panic 运行时。
    // 尺寸档不发检查，两个 label 都是 null，这里零开销。
    if (lw.panic_label) |pl| try lw.appendPanicBlock(gpa, pl, 0x5A);
    if (lw.trap_label) |tl| try lw.appendPanicBlock(gpa, tl, 0xA5);

    // M2.12：相邻拷贝折叠（去掉 mov vd,vs 的纯中转）。
    lw.foldCopies();

    // 位运算：RMW 折叠（load+op+store 同址 → 单指令 dir 级 RMW）。
    lw.foldDirRmw();

    // U2：位测试折叠（(SFR & 单比特) 比较 → jb/jnb）。
    lw.foldBitTests();

    // M2.4：循环旋转（top-test + 底部递减 → djnz）。
    // 安全网：这个改写历史上会把同一临时标签定义两遍（sqrt32/hypot 因此在硅上返回 0）。
    // 先快照，改完自检；一旦发现重复标签就整段回退 —— 宁可不优化，也不能发坏代码。
    const pre_rotate = try gpa.dupe(mcsmir.Op, lw.ops.items);
    defer gpa.free(pre_rotate);
    try lw.rotateDjnz();
    if (lw.hasDupLabels()) {
        lw.ops.clearRetainingCapacity();
        try lw.ops.appendSlice(gpa, pre_rotate);
    }

    // 部分求值（切片 A）：无参 + 纯内部计算 → 编译期算完，只留常量写回。
    // 激进优化必须显式开启：函数名以 `_fold` 结尾（如 fact_fold / sum_to_fold）。
    const fold_opt_in = std.mem.endsWith(u8, short_name, "_fold");
    if (!is_isr and lw.arg_cursor == 0 and fold_opt_in) {
        if (try lw.foldPure()) lw.saw_ret = true;
    }

    // M2.14：先做基本块内槽位复用，再挑可驻留工作寄存器的热点值。
    // 宽块的定义、读取、重命名与邻接约束必须完整，否则比较和间接调用会读旧槽。
    lw.reuseSlots();

    // 重复复杂算法压缩：统计会话内反复出现的直线算术块，把块体压成一份
    // 共享子程序，站点改发 lcall。
    //
    // **必须排在寄存器分配之前**：assignRegisters 会把 dst==lhs 的热点值搬进
    // r5/r6/r7（`.vreg` 变成 `.dir`），块内的操作数就不再是纯 vreg，整块被
    // 判定成「不可共享」而失效（槽回收把 vreg 编号压回 bank0 之后暴露）。
    // 放在这里还有个附带好处：共享例程统一用 DSEG 槽，不会被映射到工作寄存器。
    //
    // ISR 不参与：中断可能打断拥有者函数，而共享例程复用的正是拥有者的静态槽。
    // 做尺寸对照时，把下面的 enable_factor 手工改 false 再重编
    // （与 no_reuse_wide 等诊断开关同款口径）。
    const factor_base = session_vreg_base;
    factor.enabled = !is_isr and enable_factor;
    var fac = try factor.run(gpa, &lw.ops, factor_base, short_name);
    defer fac.deinit(gpa);

    // M2.13：寄存器分配（PE 折叠成功时不必——常量写回没有热点值）。
    // **ISR 一律不做**：被映射到 r0–r7 的值会被中断打断的那段主程序共用，
    // 而 ISR 现场只保存 A/PSW/DPTR/B —— 回来 rN 就错了（真机上表现为「主循环不再打印」）。
    // ISR 的槽全部留在 DSEG，就不会碰 rN。
    if (!is_isr) lw.assignRegisters();

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
        .b_live = lw.b_is_arg,
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

    // 本函数首次出现的算法模板，把共享子程序定义接在后面。后续函数里的
    // 同模板站点只发 lcall，符号在同一汇编单元可见（sdas8051 会解析）。
    if (fac.defs.items.len != 0) try mir.text.appendSlice(gpa, fac.defs.items);
    factor.dumpStats();

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

/// 从源码里抽出 `fn <name>(...)` 的真实参数名。任何一步拿不到就返回 null，
/// 调用方退回 a0 / a1（改写建议的可读性退化，但不影响正确性）。
fn sourceParamNames(
    gpa: std.mem.Allocator,
    zcu: *Zcu,
    nav: InternPool.Nav.Index,
    short_name: []const u8,
    count: usize,
) !?[]const []const u8 {
    if (count == 0) return null;
    const lazy = zcu.navSrcLoc(nav);
    const resolved = lazy.baseline.resolve(zcu) orelse return null;
    const file_idx, _ = resolved;
    const file = zcu.fileByIndex(file_idx);
    const src = file.getSource(zcu) catch return null;
    return diag.paramNamesFromSource(gpa, src[0..src.len], short_name, count) catch null;
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
