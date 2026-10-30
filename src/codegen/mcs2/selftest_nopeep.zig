//! 关窥孔的对拍入口：与 `selftest.zig` 唯一区别是 `peephole.enabled = false`。
//! 用途：确认窥孔开启前后产物语义一致（关闭态是「已知好」参照）。

const mir = @import("mir.zig");
const mcs51 = @import("mcs51.zig");
const peephole = @import("peephole.zig");

pub fn main() void {
    peephole.enabled = false;
    mcs51.emit(mir.selftest());
}
