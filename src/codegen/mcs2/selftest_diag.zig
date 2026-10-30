//! 开启窥孔命中统计的入口：与 `selftest.zig` 唯一区别是 `peephole.diag = true`。

const mir = @import("mir.zig");
const mcs51 = @import("mcs51.zig");
const peephole = @import("peephole.zig");

pub fn main() void {
    peephole.diag = true;
    mcs51.emit(mir.selftest());
}
