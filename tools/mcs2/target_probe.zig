//! 目标层探针：验证干净 0.17 的 std.Target 已认识 mcs51/mcs251，
//! 且地址空间与指针宽度符合三 profile 的前提。
//!
//! 运行（必须显式使用本仓库的 lib，而不是宿主自带 std）：
//!   zig run --zig-lib-dir lib tools/mcs2/target_probe.zig

const std = @import("std");

pub fn main() void {
    std.debug.print("mcs51  ptr bits = {d}\n", .{std.Target.ptrBitWidth_arch_abi(.mcs51, .gnu)});
    std.debug.print("mcs251 ptr bits = {d}\n", .{std.Target.ptrBitWidth_arch_abi(.mcs251, .gnu)});
    std.debug.print("addrspace.xdata = {s}\n", .{@tagName(std.lang.AddressSpace.xdata)});
    std.debug.print("addrspace.idata = {s}\n", .{@tagName(std.lang.AddressSpace.idata)});
    std.debug.print("addrspace.code  = {s}\n", .{@tagName(std.lang.AddressSpace.code)});
}
