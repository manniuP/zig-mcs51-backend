//! CORDIC：`cos`（`lib/cordic.zig`）。

const cordic = @import("cordic");

export fn ccos0() i16 {
    return cordic.cos(0);        // 0° → 0x3FFF
}