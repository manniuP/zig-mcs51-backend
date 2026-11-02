//! **B 寄存器保护**：arg0 是 32 位时，第 3 个字节落在 B(0xF0)（SDCC 边界 ABI）。
//! 表下标乘 scale 要用 `mul ab`，而 MUL 会踩 B —— 所以发射器在「本函数 B 里有活值」
//! 时会 push/pop 保护（见 mcs51.zig 的 b_live）。
//!
//! 本用例的形状：先按 scale=2 写读一次 u16 表（乘法在中间），**之后**再取 x 的高 16 位。
//! 若 B 被踩坏，`x >> 16` 就会变成脏值，结果对不上。

const T16: *volatile [8]u16 = @ptrFromInt(0x8200);

export fn bscale(x: u32, i: u8) u16 {
    T16[i] = @truncate(x);
    return T16[i] +% @as(u16, @truncate(x >> 16));
}
