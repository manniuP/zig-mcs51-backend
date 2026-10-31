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

/// 指针值：固定地址（`@ptrFromInt` 常量），或「常量基址 + 运行期下标」。
const PtrRef = union(enum) {
    fixed: u64,
    elem: struct { base: u64, idx: Loc },
};

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
    is_isr: bool = false,
    ret_byte: ?u8, // u8 返回的 ABI 地址；void 时为 null
    saw_ret: bool = false,
    /// 本函数的标签基址（跨函数不复用，避免汇编符号重名）。
    label_base: u32 = 0,
    /// 本模块是否用到 dptr（取址/解引用）。用到时 arg0（DPL）必须先搬进 vreg：
    /// 0x82 同时是 DPTR 低字节，地址计算会把它踩掉。
    needs_dptr: bool = false,

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

    /// 指针引用：固定地址，或已记录下来的「基址 + 运行期下标」。
    fn ptrRefOf(self: *Lower, ref: Air.Inst.Ref) ?PtrRef {
        if (self.constPtrAddr(ref)) |addr| return .{ .fixed = addr };
        const idx = ref.toIndex() orelse return null;
        return self.ptr_vals[@backingInt(idx)];
    }

    /// 整个编译单元是否出现会写 DPTR 的指令（保守：多算几个函数只多花 3 字节）。
    fn airNeedsDptr(self: *Lower) bool {
        const tags = self.air.instructions.items(.tag);
        const datas = self.air.instructions.items(.data);
        for (tags, 0..) |t, i| switch (t) {
            .ptr_elem_ptr, .ptr_elem_val => return true,
            .load => if (self.constPtrAddr(datas[i].ty_op.operand) != null) return true,
            .store => if (self.constPtrAddr(datas[i].bin_op.lhs) != null) return true,
            else => {},
        };
        return false;
    }

    /// 编译期 u8 常量（用于把常量下标折进固定地址）。
    fn constU8(self: *Lower, ref: Air.Inst.Ref) ?u8 {
        const ip_index = ref.toInterned() orelse return null;
        const key = self.zcu.intern_pool.indexToKey(ip_index);
        return switch (key) {
            .int => |int| switch (int.storage) {
                .u64 => |v| if (v <= 0xFF) @as(u8, @intCast(v)) else null,
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

    fn fail(self: *Lower, comptime fmt: []const u8, args: anytype) codegen.Error {
        return self.zcu.codegenFail(self.nav, "mcs2: " ++ fmt, args);
    }

    fn allocVreg(self: *Lower) !u8 {
        const total = session_vreg_base +| self.nregs;
        if (total == 255) return self.fail("帧寄存器耗尽（M1 限制 255）", .{});
        const r = self.nregs;
        self.nregs += 1;
        return r;
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
            .load_xdata_idx => |x| if (isVregByte(x.idx, from)) mcsmir.Op{ .load_xdata_idx = .{ .dst = x.dst, .base = x.base, .idx = to } } else null,
            .store_xdata_idx => |x| blk: {
                if (isVregByte(x.idx, from)) break :blk mcsmir.Op{ .store_xdata_idx = .{ .base = x.base, .idx = to, .src = x.src } };
                if (isVregByte(x.src, from)) break :blk mcsmir.Op{ .store_xdata_idx = .{ .base = x.base, .idx = x.idx, .src = to } };
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
                const lhs = try self.refLoc(bin.lhs);
                const rhs = try self.refLoc(bin.rhs);
                // 条件不成立 → else：取反。
                try self.ops.append(self.gpa, .{ .cmp_br = .{
                    .lhs = lhs,
                    .rhs = rhs,
                    .cc = cc.invert(),
                    .target = else_lbl,
                } });
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
        const tag = self.air.instructions.items(.tag)[@backingInt(inst)];
        const data = self.air.instructions.items(.data)[@backingInt(inst)];
        switch (tag) {
            .dbg_stmt, .dbg_empty_stmt, .dbg_inline_block, .dbg_var_ptr, .dbg_var_val, .dbg_arg_inline => {},

            .arg => {
                const ty = self.air.typeOfIndex(inst, &self.zcu.intern_pool);
                if (!self.typeIsU8(ty)) {
                    return self.zcu.codegenFail(
                        self.nav,
                        "mcs2: 参数类型 {s} 尚未实现（M1 只支持 u8）",
                        .{@tagName(ty.zigTypeTag(self.zcu))},
                    );
                }
                if (self.arg_cursor >= mcsmir.abi.max_arg_bytes) {
                    return self.zcu.codegenFail(
                        self.nav,
                        "mcs2: 参数超过 {d} 字节寄存器 ABI（M1）",
                        .{mcsmir.abi.max_arg_bytes},
                    );
                }
                // ADR-001 边界 ABI：arg0 → DPL；arg1+ → 静态 `_名_PARM_n`（SDCC 同款）。
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
                        .{ self.short_name, self.arg_cursor + 1 },
                    );
                    try self.parms.append(self.gpa, psym);
                    self.vals[@backingInt(inst)] = .{ .sym = psym };
                }
                self.arg_cursor += 1;
            },

            .ptr_elem_ptr => {
                // 运行期下标：基址必须是固定地址（@ptrFromInt；全局符号待 M2.5 后补）。
                const bin = self.air.extraData(Air.Bin, @intCast(data.ty_pl.payload)).data;
                const pr = self.ptrRefOf(bin.lhs) orelse
                    return self.fail("指针下标的基址必须是固定地址（暂不支持运行期指针）", .{});
                switch (pr) {
                    .fixed => |base| {
                        // 常量下标直接折进固定地址，保持原有常量地址路径。
                        if (self.constU8(bin.rhs)) |k| {
                            self.ptr_vals[@backingInt(inst)] = .{ .fixed = base + k };
                            continue;
                        }
                        const idx_loc = try self.refLoc(bin.rhs);
                        self.ptr_vals[@backingInt(inst)] = .{ .elem = .{ .base = base, .idx = idx_loc } };
                    },
                    .elem => return self.fail("多级下标（链式指针运算）暂不支持", .{}),
                }
            },

            .add, .add_safe, .add_wrap, .sub, .sub_safe, .sub_wrap => {
                const bin = data.bin_op;
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

            .bit_and, .bit_or, .xor => {
                const ty = self.air.typeOfIndex(inst, &self.zcu.intern_pool);
                if (!self.typeIsU8(ty)) return self.fail("位运算只支持 u8（暂不实现其它宽度）", .{});
                const bin = data.bin_op;
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

            // 整数转换：≤16 位一律透传（本后端只跟踪 8 位值；下标被当作 u8 使用）。
            // 目的：让 `buf[i]`（i: u8 → usize 下标）不再被拒绝。
            .int_cast, .int_cast_safe, .trunc => {
                const ty_op = data.ty_op;
                const src_ty = self.air.typeOf(ty_op.operand, &self.zcu.intern_pool);
                const dst_ty = self.air.typeOfIndex(inst, &self.zcu.intern_pool);
                // 只跟踪 8 位：放宽（源 ≤8 位）与截断（目标 ≤8 位）都不改低字节，
                // 可以原样透传；两侧都更宽时语义不可丢失，直接拒绝。
                const src_bits = src_ty.bitSize(self.zcu);
                const dst_bits = dst_ty.bitSize(self.zcu);
                if (src_bits > 8 and dst_bits > 8)
                    return self.fail("整数转换两侧都超过 8 位（M1 只跟踪低字节）", .{});
                self.vals[@backingInt(inst)] = try self.refLoc(ty_op.operand);
            },

            .alloc => {
                // M1：每个局部槽一个 vreg（DSEG 直址）；活跃期优化留给后续 pass。
                const r = try self.allocVreg();
                self.vals[@backingInt(inst)] = mcsmir.v(r);
            },

            .store, .store_safe => {
                // bin_op：lhs = 目标，rhs = 值。
                // 目标为固定地址指针（@ptrFromInt）：≤0xFF → SFR/直址；>0xFF → xdata。
                const bin = data.bin_op;
                if (self.ptrRefOf(bin.lhs)) |pr| {
                    const value = try self.refLoc(bin.rhs);
                    switch (pr) {
                        .fixed => |addr| {
                            if (addr <= 0xFF) {
                                try self.ops.append(self.gpa, .{ .store_dir = .{ .addr = @intCast(addr), .src = value } });
                            } else if (addr <= 0xFFFF) {
                                try self.ops.append(self.gpa, .{ .store_xdata = .{ .addr = @intCast(addr), .src = value } });
                            } else return self.fail("固定地址 0x{X} 超出 51 可寻址范围", .{addr});
                        },
                        .elem => |e| {
                            if (e.base > 0xFFFF) return self.fail("下标基址 0x{X} 超出 51 可寻址范围", .{e.base});
                            if (e.base <= 0xFF) return self.fail("直址（≤0xFF）暂不支持运行期下标：需要 @r0/@r1 间接寻址", .{});
                            try self.ops.append(self.gpa, .{ .store_xdata_idx = .{
                                .base = @intCast(e.base),
                                .idx = e.idx,
                                .src = value,
                            } });
                        },
                    }
                    continue;
                }
                const dest = try self.refLoc(bin.lhs);
                const value = try self.refLoc(bin.rhs);
                try self.ops.append(self.gpa, .{ .mov = .{ .dst = dest, .src = value } });
                // store 本身无结果值
            },

            // `buf[i]` 的读取形态：AIR 把「取元素指针 + 解引用」折成 ptr_elem_val。
            .ptr_elem_val => {
                const bin = data.bin_op;
                const pr = self.ptrRefOf(bin.lhs) orelse
                    return self.fail("元素读取的基址必须是固定地址（暂不支持运行期指针）", .{});
                const r = try self.allocVreg();
                switch (pr) {
                    .fixed => |base| {
                        if (self.constU8(bin.rhs)) |k| {
                            const addr = base + k;
                            if (addr <= 0xFF) {
                                try self.ops.append(self.gpa, .{ .load_dir = .{ .dst = mcsmir.v(r), .addr = @intCast(addr) } });
                            } else if (addr <= 0xFFFF) {
                                try self.ops.append(self.gpa, .{ .load_xdata = .{ .dst = mcsmir.v(r), .addr = @intCast(addr) } });
                            } else return self.fail("地址 0x{X} 超出 51 可寻址范围", .{addr});
                        } else {
                            if (base <= 0xFF) return self.fail("直址（≤0xFF）暂不支持运行期下标：需要 @r0/@r1 间接寻址", .{});
                            if (base > 0xFFFF) return self.fail("下标基址 0x{X} 超出 51 可寻址范围", .{base});
                            const idx_loc = try self.refLoc(bin.rhs);
                            try self.ops.append(self.gpa, .{ .load_xdata_idx = .{
                                .dst = mcsmir.v(r),
                                .base = @intCast(base),
                                .idx = idx_loc,
                            } });
                        }
                    },
                    .elem => return self.fail("多级下标（链式指针运算）暂不支持", .{}),
                }
                self.vals[@backingInt(inst)] = mcsmir.v(r);
            },

            .load => {
                // ty_op：operand = 指针。固定地址 → load_dir（≤0xFF）/ load_xdata（>0xFF）；
                // 本地槽 → 直读。
                const ty_op = data.ty_op;
                if (self.ptrRefOf(ty_op.operand)) |pr| {
                    const r = try self.allocVreg();
                    switch (pr) {
                        .fixed => |addr| {
                            if (addr <= 0xFF) {
                                try self.ops.append(self.gpa, .{ .load_dir = .{ .dst = mcsmir.v(r), .addr = @intCast(addr) } });
                            } else if (addr <= 0xFFFF) {
                                try self.ops.append(self.gpa, .{ .load_xdata = .{ .dst = mcsmir.v(r), .addr = @intCast(addr) } });
                            } else return self.fail("固定地址 0x{X} 超出 51 可寻址范围", .{addr});
                        },
                        .elem => |e| {
                            if (e.base > 0xFFFF) return self.fail("下标基址 0x{X} 超出 51 可寻址范围", .{e.base});
                            if (e.base <= 0xFF) return self.fail("直址（≤0xFF）暂不支持运行期下标：需要 @r0/@r1 间接寻址", .{});
                            try self.ops.append(self.gpa, .{ .load_xdata_idx = .{
                                .dst = mcsmir.v(r),
                                .base = @intCast(e.base),
                                .idx = e.idx,
                            } });
                        },
                    }
                    self.vals[@backingInt(inst)] = mcsmir.v(r);
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
                    const loc = try self.refLoc(operand);
                    const already = switch (loc) {
                        .dir => |a| a == rb,
                        else => false,
                    };
                    if (!already) {
                        try self.ops.append(self.gpa, .{ .store_dir = .{ .addr = rb, .src = loc } });
                    }
                }
                try self.ops.append(self.gpa, .{ .ret = {} });
                self.saw_ret = true;
                return true;
            },


            .br => {
                // break / 跳块：目标 = 该块定义指令的“出口”标签。
                try self.ops.append(self.gpa, .{ .br = self.blockEnd(data.br.block_inst) });
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
                const blk = self.air.unwrapBlock(inst);
                const inner = try self.emitBody(blk.body);
                const end_l = self.blockEnd(inst);
                // 块内已终结且没人 break 到块尾 → 整个块也不会落空（while(true) 的常见形态）
                if (inner and !self.labelReferenced(end_l)) return true;
                try self.ops.append(self.gpa, .{ .label = end_l });
            },
            .cmp_lt, .cmp_lt_optimized, .cmp_lte, .cmp_lte_optimized,
            .cmp_gt, .cmp_gt_optimized, .cmp_gte, .cmp_gte_optimized,
            .cmp_eq, .cmp_eq_optimized, .cmp_neq, .cmp_neq_optimized => {
                // M2 第一刀：比较指令本身不发码——它只作为 cond_br 的条件，
                // 由 emitCondBr 融合成 cmp_br。若结果被当值使用，refLoc 会报错。
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
        if (ret_ty.zigTypeTag(zcu) != .int or ret_ty.bitSize(zcu) != 8 or ret_ty.isSignedInt(zcu)) {
            return zcu.codegenFail(
                func.owner_nav,
                "mcs2: 返回类型 {s} 尚未实现（M1 只支持 void/u8）",
                .{@tagName(ret_ty.zigTypeTag(zcu))},
            );
        }
        break :blk mcsmir.abi.dpl;
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

    const body = air.getMainBody();
    lw.vals = try gpa.alloc(?Loc, air.instructions.len);
    defer gpa.free(lw.vals);
    @memset(lw.vals, null);

    lw.ptr_vals = try gpa.alloc(?PtrRef, air.instructions.len);
    defer gpa.free(lw.ptr_vals);
    @memset(lw.ptr_vals, null);

    lw.needs_dptr = lw.airNeedsDptr();

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

    // M2.4：循环旋转（top-test + 底部递减 → djnz）。
    try lw.rotateDjnz();

    // 部分求值（切片 A）：无参 + 纯内部计算 → 编译期算完，只留常量写回。
    // 激进优化必须显式开启：函数名以 `_fold` 结尾（如 fact_fold / sum_to_fold）。
    const fold_opt_in = std.mem.endsWith(u8, short_name, "_fold");
    if (!is_isr and lw.arg_cursor == 0 and fold_opt_in) {
        if (try lw.foldPure()) lw.saw_ret = true;
    }

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
    defer gpa.free(f.parms);
    const text = try mcs51.compileEx(f, gpa, false);
    defer gpa.free(text);

    var mir: Mir = .{};
    errdefer mir.deinit(gpa);
    try mir.text.appendSlice(gpa, text);

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
