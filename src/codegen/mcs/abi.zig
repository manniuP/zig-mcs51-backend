//! SDCC MCS251 ABI revision 2 的参数 / 返回值分类。
//!
//! 参考：`sdcc-c251/doc/mcs251/abi.md`。本端口不声称与 Arm/Keil MCS251 ABI
//! 或 OMF-251 目标文件 / 库互操作。
//!
//! 要点（rev 2）：
//!   - 首个标量参数与标量返回值使用普通 SDCC 返回寄存器：
//!     1 字节在 DPL，字在 DPH:DPL（数值），4 字节标量在 A:B:DPH:DPL。
//!     这里按“逻辑最低字节到最高字节”列出，故 DPL 为最低字节。
//!   - 3 字节指针使用 DPL/DPH/B（最高字节在 B），写作 B:DPH:DPL。
//!   - 其余非可重入参数使用 SDCC 的可覆盖参数区；可重入栈参数使用硬件栈。
//!   - 大型聚合返回使用 SDCC 隐藏结果指针约定。
//!   - 标量在存储器中为大端：最高字节位于最低地址。

const std = @import("std");

const Type = @import("../../Type.zig");
const Zcu = @import("../../Zcu.zig");

/// ABI 版本号。任何影响对象布局的改动都必须递增。
pub const revision: u8 = 2;

/// 用于承载首个标量参数 / 返回值的寄存器槽。
pub const Primary = enum {
    /// 无运行时值（void、零位类型等）。
    none,
    /// 1 字节：DPL。
    dpl,
    /// 2 字节：DPH:DPL（数值）。
    dpl_dph,
    /// 3 字节：B:DPH:DPL（指针，最高字节在 B）。
    dpl_dph_b,
    /// 4 字节：A:B:DPH:DPL（最高字节在 A）。
    dpl_dph_b_a,
    /// 无法放入寄存器槽：按大端入栈，或经隐藏指针返回。
    memory,
};

/// 一个值的 ABI 分类结果。
pub const Class = struct {
    /// 主寄存器槽。
    primary: Primary,
    /// 对象的 ABI 字节大小。
    size: u32,
    /// 是否为聚合类型（结构体 / 联合 / 数组 / 向量）。
    is_aggregate: bool,
};

/// 按 ABI 大小与类型种类进行分类。
pub fn classify(ty: Type, zcu: *const Zcu) Class {
    const size: u32 = @intCast(ty.abiSize(zcu));
    const is_aggregate = switch (ty.zigTypeTag(zcu)) {
        .@"struct", .@"union", .array, .vector => true,
        else => false,
    };
    return .{
        .primary = classifySize(size),
        .size = size,
        .is_aggregate = is_aggregate,
    };
}

/// 仅按大小给出寄存器槽。纯函数，便于测试。
pub fn classifySize(size: u32) Primary {
    return switch (size) {
        0 => .none,
        1 => .dpl,
        2 => .dpl_dph,
        3 => .dpl_dph_b,
        4 => .dpl_dph_b_a,
        else => .memory,
    };
}

/// 分类并只返回主寄存器槽（`classify` 的便捷包装）。
pub fn classifyType(ty: Type, zcu: *const Zcu) Primary {
    return classify(ty, zcu).primary;
}

/// 主寄存器槽占用的字节数。
pub fn registerBytes(p: Primary) u8 {
    return switch (p) {
        .none, .memory => 0,
        .dpl => 1,
        .dpl_dph => 2,
        .dpl_dph_b => 3,
        .dpl_dph_b_a => 4,
    };
}

/// 主寄存器槽中的字节（从最低有效字节起），用于生成寄存器搬运序列。
/// 返回的每一项是 `encode.Register` 名称所对应的硬件寄存器。
pub const ByteReg = enum { dpl, dph, b, a };

/// 返回主寄存器槽从最低有效字节到最高有效字节的寄存器序列。
pub fn byteRegisters(p: Primary) []const ByteReg {
    return switch (p) {
        .none, .memory => &.{},
        .dpl => &.{.dpl},
        .dpl_dph => &.{ .dpl, .dph },
        .dpl_dph_b => &.{ .dpl, .dph, .b },
        .dpl_dph_b_a => &.{ .dpl, .dph, .b, .a },
    };
}

// ---------------------------------------------------------------------------
// 测试（仅纯函数）
// ---------------------------------------------------------------------------

const testing = std.testing;

test "按大小分类" {
    try testing.expectEqual(Primary.none, classifySize(0));
    try testing.expectEqual(Primary.dpl, classifySize(1));
    try testing.expectEqual(Primary.dpl_dph, classifySize(2));
    try testing.expectEqual(Primary.dpl_dph_b, classifySize(3));
    try testing.expectEqual(Primary.dpl_dph_b_a, classifySize(4));
    try testing.expectEqual(Primary.memory, classifySize(5));
    try testing.expectEqual(Primary.memory, classifySize(8));
}

test "寄存器槽字节数" {
    try testing.expectEqual(@as(u8, 1), registerBytes(.dpl));
    try testing.expectEqual(@as(u8, 2), registerBytes(.dpl_dph));
    try testing.expectEqual(@as(u8, 3), registerBytes(.dpl_dph_b));
    try testing.expectEqual(@as(u8, 4), registerBytes(.dpl_dph_b_a));
    try testing.expectEqual(@as(u8, 0), registerBytes(.memory));
}

test "字节寄存器顺序为最低字节在前" {
    try testing.expectEqualSlices(ByteReg, &.{}, byteRegisters(.none));
    try testing.expectEqualSlices(ByteReg, &.{.dpl}, byteRegisters(.dpl));
    try testing.expectEqualSlices(ByteReg, &.{ .dpl, .dph }, byteRegisters(.dpl_dph));
    try testing.expectEqualSlices(ByteReg, &.{ .dpl, .dph, .b }, byteRegisters(.dpl_dph_b));
    try testing.expectEqualSlices(ByteReg, &.{ .dpl, .dph, .b, .a }, byteRegisters(.dpl_dph_b_a));
}
