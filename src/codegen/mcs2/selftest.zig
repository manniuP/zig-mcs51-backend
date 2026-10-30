//! mcs2 垂直切片入口：MIR → MCS51 汇编。
//!
//! 输出走 stderr，调用方用 `2> build/out.asm` 捕获；这样不依赖 0.17 的新 Io API。
//!
//! 窥孔开关是 `peephole.enabled`（模块级 pub var，默认开）。
//! 对拍用关窥孔的入口见 `selftest_nopeep.zig`；
//! 命中统计（`peephole.diag`）由 `selftest_diag.zig` 打开。

const mir = @import("mir.zig");
const mcs51 = @import("mcs51.zig");

pub fn main() void {
    mcs51.emit(mir.selftest());
}
