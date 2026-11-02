//! CORDIC：atan2（`lib/cordic.zig`）。

const cordic = @import("cordic");

export fn cat90() i16 {
    return cordic.atan2(16384, 0);       // 90° → 0x2000
}

export fn cat45() i16 {
    return cordic.atan2(16384, 16384);   // 45° → 0x1000
}