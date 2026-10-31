//! mcs2 的最小 MIR 模型（迁移起点）。
//!
//! 这不是最终 AIR 降级层：当前覆盖无调用、单字节算术、xdata 写与基本控制流。
//! 目的：先把「结构化 IR → 目标汇编」的边界固定下来，后续再把 AIR 接进来。

const std = @import("std");

/// 三个 profile 的语义边界。指针宽度是 ABI 的一部分，不是后端偏好。
pub const Profile = enum {
    /// MCS51：2 字节 xdata 指针，SDCC ABI，sdas8051/sdld。
    mcs51_sdcc,
    /// MCS251-ASM：3 字节指针，SDCC ABI，sdas251/sdld。
    mcs251_sdcc,
    /// MCS251-LLVM：4 字节容器、24 位有效地址，clang/LLVM 链路。
    mcs251_llvm,
};

pub fn pointerBytes(profile: Profile) u8 {
    return switch (profile) {
        .mcs51_sdcc => 2,
        .mcs251_sdcc => 3,
        .mcs251_llvm => 4,
    };
}

/// 一个 8 位值的位置：虚拟寄存器（DSEG 帧槽）、直接地址（含 SFR/ABI 寄存器）、
/// 或符号直址（边界 ABI 的 `_函数名_PARM_n` 静态参数区、未来的具名全局）。
/// 三者在 51 上都走 direct 寻址，发射层只是文本名不同。
pub const Byte = union(enum) {
    vreg: u8,
    dir: u8,
    sym: []const u8,
    /// 立即数（P1.5：常量不再先物化到 vreg，直接当操作数）。
    imm: u8,
};

/// 虚拟寄存器位置的简写。
pub fn v(n: u8) Byte {
    return .{ .vreg = n };
}

/// ABI 合同（双轨制，见 docs/ADR-001-双ABI策略-2026-10-30.md）：
///   - **边界 ABI**（仅 `export/extern fn`）：与 SDCC `-mmcs51 --model-small`
///     逐字节对齐——arg0→DPL，arg1+→静态 `_函数名_PARM_n` 区（**不是 DPH**，
///     SDCC 4.6 实测；`--sdcccall=1` 不改变），返回→DPL。真值=SDCC 实测产物。
///   - **内部 ABI**（纯 Zig 间调用，M2 落地）：按最优值位置设计，候选 Keil
///     风格寄存器传参；只在 `mcs2/abi.zig`（规划中）一处定义。
///   - 下面的 `arg_regs` 是 M1 过渡形态（arg1=DPH），M1 收尾项之一是
///     把边界函数的 arg1+ 改为 PARM 区，见 ADR-001 §4.1。
pub const abi = struct {
    pub const dpl: u8 = 0x82;
    pub const dph: u8 = 0x83;
    pub const b: u8 = 0xF0;
    pub const acc: u8 = 0xE0;
    pub const arg_regs = [4]u8{ dpl, dph, b, acc };
    pub const max_arg_bytes = arg_regs.len;
};

/// 比较条件码（8 位无符号语义）。
pub const Cc = enum {
    lt,
    le,
    gt,
    ge,
    eq,
    ne,

    /// 取反：cond_br 的 else 分支用。
    pub fn invert(self: Cc) Cc {
        return switch (self) {
            .lt => .ge,
            .le => .gt,
            .gt => .le,
            .ge => .lt,
            .eq => .ne,
            .ne => .eq,
        };
    }
};

pub const Op = union(enum) {
    /// 把 8 位立即数写入目标位置。
    imm: struct { dst: Byte, value: u8 },
    /// dst = lhs + rhs（8 位，回绕）。发射：`mov a,lhs; add a,rhs; mov dst,a`。
    add: struct { dst: Byte, lhs: Byte, rhs: Byte },
    /// dst = lhs - rhs（8 位，回绕）。发射：`clr c; mov a,lhs; subb a,rhs; mov dst,a`。
    sub: struct { dst: Byte, lhs: Byte, rhs: Byte },
    /// dst = lhs & rhs（按位与）。发射：`mov a,lhs; anl a,rhs; mov dst,a`。
    and_: struct { dst: Byte, lhs: Byte, rhs: Byte },
    /// dst = lhs | rhs（按位或）。发射：`mov a,lhs; orl a,rhs; mov dst,a`。
    or_: struct { dst: Byte, lhs: Byte, rhs: Byte },
    /// dst = lhs ^ rhs（按位异或）。发射：`mov a,lhs; xrl a,rhs; mov dst,a`。
    xor_: struct { dst: Byte, lhs: Byte, rhs: Byte },
    /// dst -= 1（8 位，回绕；8051 的 `dec direct`）。
    dec: u8,
    /// dst <- 直接地址 mem[addr]（读 SFR/ABI 寄存器等）。
    load_dir: struct { dst: Byte, addr: u8 },
    /// dst <- xdata mem[addr]（16 位，`mov dptr,#imm` + `movx a,@dptr` + `mov dst,a`）。
    load_xdata: struct { dst: Byte, addr: u16 },
    /// 压栈/出栈（操作数为直接地址；ISR 现场保存用，`push 0xE0` 合法）。
    push: struct { src: Byte },
    pop: struct { dst: Byte },
    /// 中断返回（ISR 专用；恢复现场由显式 pop 完成）。
    reti,
    /// mem[addr] <- src（写 SFR/ABI 寄存器等）。
    store_dir: struct { addr: u8, src: Byte },
    /// 把源位置写入 xdata 的 16 位绝对地址。
    store_xdata: struct { addr: u16, src: Byte },
    /// dst <- xdata mem[base + idx]（运行期下标：dptr = base + idx，base 须为常量）。
    load_xdata_idx: struct { dst: Byte, base: u16, idx: Byte },
    /// xdata mem[base + idx] <- src（运行期下标）。
    store_xdata_idx: struct { base: u16, idx: Byte, src: Byte },
    /// 局部标签定义，供 br/br_ifnz 引用。
    label: u32,
    /// 无条件跳转到标签。
    br: u32,
    /// dst <- src（8 位搬运；直址到直址合法）。
    mov: struct { dst: Byte, src: Byte },
    /// 递减并跳转（M2.4 / djnz）：dst -= 1；若结果非零则跳到 target。
    dec_br_nz: struct { dst: Byte, target: u32 },
    /// 比较 + 条件跳转（融合形态）：cc 成立则跳到 target。
    /// 51 发射为 clr c / mov a / subb / jcc，或 xrl / jz(jnz)。
    cmp_br: struct { lhs: Byte, rhs: Byte, cc: Cc, target: u32 },
    /// 位置值非零则跳转（发射为 `mov a,src` + `jnz rel` 两步；
    /// 8051 的 JZ/JNZ 只测 A，不测 direct）。
    br_ifnz: struct { cond: Byte, target: u32 },
    /// 位置值为零则跳转（`mov a,src` + `jz rel`）；cond_br 的 else 分支用。
    br_ifz: struct { cond: Byte, target: u32 },
    /// 函数返回（51: `ret`；返回值由调用方先放好，见 `abi`）。
    ret,
    /// 停机；当前切片不建立调用栈。
    halt,
};

pub const Function = struct {
    name: []const u8,
    profile: Profile,
    nregs: u8,
    /// 本函数 vreg 的全局基线（同模块多函数时 DSEG 槽不撞名）。
    vreg_base: u8 = 0,
    ops: []const Op,
    /// 边界 ABI 的静态参数区符号（`_name_PARM_n`），DSEG 段各 `.ds 1`。
    /// 空表 = 无静态参数（M1 的 u8 单参函数即空）。
    parms: []const []const u8 = &.{},
};

/// 一个极小的自检程序：
///   1) 3 + 4 -> xdata 0x8000（旧验收不变）；
///   2) 倒数循环：v2 从 3 递减，逐次写 0x8001，结束写 0x8002=0；
///   3) 可穿线模式：br_ifnz 跳到 L1，L1 紧跟 sjmp L2 —— 窥孔 R1 应把
///      目标改写到 L2、R2 应删除 L1+sjmp（L1 引用归零后）；
///      随后写 0x8003 = v1 = 1 验证执行路径不变；
///   4) halt 之后的死块：窥孔 R2 应整块删除。
const selftest_ops = [_]Op{
    // (1) 3 + 4
    .{ .imm = .{ .dst = v(0), .value = 3 } },
    .{ .imm = .{ .dst = v(1), .value = 4 } },
    .{ .add = .{ .dst = v(2), .lhs = v(0), .rhs = v(1) } },
    .{ .store_xdata = .{ .addr = 0x8000, .src = v(2) } },
    // (2) 倒数循环（label 0 = loop）
    .{ .imm = .{ .dst = v(2), .value = 3 } },
    .{ .label = 0 },
    .{ .store_xdata = .{ .addr = 0x8001, .src = v(2) } },
    .{ .dec = 2 },
    .{ .br_ifnz = .{ .cond = v(2), .target = 0 } },
    .{ .store_xdata = .{ .addr = 0x8002, .src = v(2) } },
    // (3) 可穿线模式（label 1 = L1, label 2 = L2）
    .{ .imm = .{ .dst = v(1), .value = 1 } },
    .{ .br_ifnz = .{ .cond = v(1), .target = 1 } },
    .{ .label = 1 },
    .{ .br = 2 },
    .{ .label = 2 },
    .{ .store_xdata = .{ .addr = 0x8003, .src = v(1) } },
    .halt,
    // (4) halt 之后的死块：窥孔 R2 应整块删除（前驱是 sjmp 转移）。
    //     ucsim 永远执行不到，删与不删行为一致，但条目流应干净。
    .{ .label = 3 },
    .{ .br = 4 },
    .{ .label = 4 },
};

pub fn selftest() Function {
    return .{
        .name = "main",
        .profile = .mcs51_sdcc,
        .nregs = 3,
        .ops = &selftest_ops,
    };
}

test "profile pointer widths" {
    try std.testing.expectEqual(@as(u8, 2), pointerBytes(.mcs51_sdcc));
    try std.testing.expectEqual(@as(u8, 3), pointerBytes(.mcs251_sdcc));
    try std.testing.expectEqual(@as(u8, 4), pointerBytes(.mcs251_llvm));
}
