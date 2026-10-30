//! mcs2 调试信息接口（预留，暂不实现 SDCC `.cdb`）。
//!
//! 设计目的：把“后端产生调试信息”与“调试信息写到哪种格式”解耦。
//! 当前只提供数据模型与 sink 接口；真正的 `.cdb` 编码器留到后续阶段。
//!
//! 约定：
//!   - 51 的原生调试格式是 `sdld -y` 生成的 `.cdb`，不是 ELF/DWARF；
//!   - 251-LLVM 走 ELF，后续再补 DWARF；
//!   - 本模块不依赖 SDCC，也不产生任何文件。

const std = @import("std");

pub const SourceLoc = struct {
    file: []const u8,
    line: u32,
    column: u32,
};

pub const SymbolKind = enum {
    function,
    data,
    code,
    xdata,
};

pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind,
    /// 目标地址；尚未布局时可为 0。
    addr: u32 = 0,
    /// 字节大小；未知时为 0。
    size: u32 = 0,
    loc: ?SourceLoc = null,
};

pub const Line = struct {
    addr: u32,
    loc: SourceLoc,
};

pub const DebugInfo = struct {
    symbols: []const Symbol = &.{},
    lines: []const Line = &.{},
};

/// 调试信息接收端。实现方可以是 `.cdb` 写入器、ELF/DWARF 写入器或测试桩。
pub const Sink = struct {
    context: *anyopaque,
    emit_fn: *const fn (context: *anyopaque, info: *const DebugInfo) anyerror!void,

    pub fn emit(self: Sink, info: *const DebugInfo) anyerror!void {
        return self.emit_fn(self.context, info);
    }
};

/// 空 sink：用于“暂不生成调试信息”的路径。
pub fn ignore(_: *anyopaque, _: *const DebugInfo) anyerror!void {}

test "sink dispatch" {
    var count: usize = 0;
    const Ctx = struct {
        fn bump(ctx: *anyopaque, _: *const DebugInfo) anyerror!void {
            const p: *usize = @ptrCast(@alignCast(ctx));
            p.* += 1;
        }
    };
    const sink = Sink{
        .context = @ptrCast(&count),
        .emit_fn = Ctx.bump,
    };
    const info = DebugInfo{};
    try sink.emit(&info);
    try std.testing.expectEqual(@as(usize, 1), count);
}
