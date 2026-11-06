//! 算术右移（有符号 >>）：符号位必须补回高位，不能按逻辑右移补 0。

// 32 位：-16 >> 3 = -2（逻辑右移会得 0x1FFFFFFE）
export fn sar32(x: i32) i32 {
    return x >> 3;
}

// 8 位（n=1 走同一条模板）：-16 >> 2 = -4（逻辑右移会得 0x3C）
export fn sar8(x: i8) i8 {
    return x >> 2;
}

// ---- 同一个 4 字节模板家族的另外两份：逻辑右移 / 左移 ----
// 逻辑右移必须补 0（0x80000000 >> 4 = 0x08000000），模板每轮 clr c。
export fn shr32t(x: u32) u32 {
    return x >> 4;
}

// 左移从最低字节往上 rlc（0x12345678 << 4 = 0x23456780，最高位溢出丢弃）。
export fn shl32t(x: u32) u32 {
    return x << 4;
}

// 左移跨字节进位：0x000000FF << 8 = 0x0000FF00（验证 rlc 链的进位传递）
export fn shl32c(x: u32) u32 {
    return x << 8;
}
