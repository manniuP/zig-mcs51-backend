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
    parms: std.ArrayListUnmanaged([]const u8) = .empty,
    is_isr: bool = false,
    ret_byte: ?u8, // u8 返回的 ABI 地址；void 时为 null
    saw_ret: bool = false,
    /// 本函数的标签基址（跨函数不复用，避免汇编符号重名）。
    label_base: u32 = 0,

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
                        const dst = try self.allocVreg();
                        try self.ops.append(self.gpa, .{ .imm = .{ .dst = mcsmir.v(dst), .value = @intCast(v) } });
                        return mcsmir.v(dst);
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
    for (body, 0..) |inst, idx| {
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
                    self.vals[@backingInt(inst)] = .{ .dir = mcsmir.abi.arg_regs[0] };
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
                const dst: Loc = if (consumed_by_ret)
                    .{ .dir = self.ret_byte.? }
                else
                    mcsmir.v(try self.allocVreg());
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

            .alloc => {
                // M1：每个局部槽一个 vreg（DSEG 直址）；活跃期优化留给后续 pass。
                const r = try self.allocVreg();
                self.vals[@backingInt(inst)] = mcsmir.v(r);
            },

            .store, .store_safe => {
                // bin_op：lhs = 目标，rhs = 值。
                // 目标为固定地址指针（@ptrFromInt）：≤0xFF → SFR/直址；>0xFF → xdata。
                const bin = data.bin_op;
                if (self.constPtrAddr(bin.lhs)) |addr| {
                    const value = try self.refLoc(bin.rhs);
                    if (addr <= 0xFF) {
                        try self.ops.append(self.gpa, .{ .store_dir = .{ .addr = @intCast(addr), .src = value } });
                    } else if (addr <= 0xFFFF) {
                        try self.ops.append(self.gpa, .{ .store_xdata = .{ .addr = @intCast(addr), .src = value } });
                    } else return self.fail("固定地址 0x{X} 超出 51 可寻址范围", .{addr});
                    continue;
                }
                const dest = try self.refLoc(bin.lhs);
                const value = try self.refLoc(bin.rhs);
                try self.ops.append(self.gpa, .{ .mov = .{ .dst = dest, .src = value } });
                // store 本身无结果值
            },

            .load => {
                // ty_op：operand = 指针。固定地址 → load_dir（≤0xFF）/ load_xdata（>0xFF）；
                // 本地槽 → 直读。
                const ty_op = data.ty_op;
                if (self.constPtrAddr(ty_op.operand)) |addr| {
                    const r = try self.allocVreg();
                    if (addr <= 0xFF) {
                        try self.ops.append(self.gpa, .{ .load_dir = .{ .dst = mcsmir.v(r), .addr = @intCast(addr) } });
                    } else if (addr <= 0xFFFF) {
                        try self.ops.append(self.gpa, .{ .load_xdata = .{ .dst = mcsmir.v(r), .addr = @intCast(addr) } });
                    } else return self.fail("固定地址 0x{X} 超出 51 可寻址范围", .{addr});
                    self.vals[@backingInt(inst)] = mcsmir.v(r);
                    continue;
                }
                const src = try self.refLoc(ty_op.operand);
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
                _ = try self.emitBody(blk.body);
                try self.ops.append(self.gpa, .{ .label = self.blockEnd(inst) });
            },
            .block => {
                const blk = self.air.unwrapBlock(inst);
                _ = try self.emitBody(blk.body);
                try self.ops.append(self.gpa, .{ .label = self.blockEnd(inst) });
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

    _ = try lw.emitBody(body);

    if (!lw.saw_ret) {
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
