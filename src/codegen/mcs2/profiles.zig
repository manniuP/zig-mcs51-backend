//! 三套 MCS profile 的目标参数。
//!
//! 这里是“单一事实来源”的起点：指针宽度、对象格式、工具链与调试格式
//! 不允许散落在后端、脚本和文档里。

const std = @import("std");
const mir = @import("mir.zig");

pub const ObjectFormat = enum { hex, elf };
pub const Assembler = enum { sdas8051, sdas251, llc };
pub const Linker = enum { sdld, mcs251_lld };
pub const DebugFormat = enum { none, cdb, dwarf };

pub const Info = struct {
    profile: mir.Profile,
    pointer_bytes: u8,
    object_format: ObjectFormat,
    assembler: Assembler,
    linker: Linker,
    debug_format: DebugFormat,
};

pub fn info(profile: mir.Profile) Info {
    return switch (profile) {
        .mcs51_sdcc => .{
            .profile = profile,
            .pointer_bytes = 2,
            .object_format = .hex,
            .assembler = .sdas8051,
            .linker = .sdld,
            .debug_format = .cdb,
        },
        .mcs251_sdcc => .{
            .profile = profile,
            .pointer_bytes = 3,
            .object_format = .hex,
            .assembler = .sdas251,
            .linker = .sdld,
            .debug_format = .cdb,
        },
        .mcs251_llvm => .{
            .profile = profile,
            .pointer_bytes = 4,
            .object_format = .elf,
            .assembler = .llc,
            .linker = .mcs251_lld,
            .debug_format = .dwarf,
        },
    };
}

test "profile table matches mir pointer widths" {
    inline for (std.meta.tags(mir.Profile)) |p| {
        try std.testing.expectEqual(mir.pointerBytes(p), info(p).pointer_bytes);
    }
}
