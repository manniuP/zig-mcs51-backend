//! CORDIC：sqrt / hypot（`lib/cordic.zig`）。

const cordic = @import("cordic");

export fn csqrt1m() u16 {
    return cordic.sqrt32(1_000_000);   // → 1000
}

export fn chyp() u16 {
    return cordic.hypot(3, 4);         // → 5
}