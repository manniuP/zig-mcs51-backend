//! 多字节乘法：只用 MUL AB 的固定模板（无符号与有符号的低位结果一致）。

// 16×16→16：3 次 MUL（低位积 + 两个交叉项的高字节）
// 0x0102 * 0x0304 = 0x30A08 → 取低 16 位 0x0A08
export fn u16mul(a: u16, b: u16) u16 {
    return a *% b;
}

// 有符号 16 位乘法的低位与无符号一致：-3 * 5 = -15 = 0xFFF1
export fn i16mul(a: i16, b: i16) i16 {
    return a *% b;
}
