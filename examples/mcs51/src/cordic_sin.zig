//! CORDIC：`sin`（`lib/cordic.zig`）。一个模块只放一个库函数（DSEG 80 B 很紧）。

const cordic = @import("cordic");

export fn csin90() i16 {
    return cordic.sin(0x4000);   // 90° → 0x3FFF
}

export fn csin45() i16 {
    return cordic.sin(0x2000);   // 45° → 0x2D42
}

export fn csin180() i16 {
    return cordic.sin(-32768);   // 180°（0x8000 的位模式）→ 0x0005，验象限折返
}