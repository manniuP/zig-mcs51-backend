//! 算术右移（有符号 >>）：符号位必须补回高位，不能按逻辑右移补 0。

// 32 位：-16 >> 3 = -2（逻辑右移会得 0x1FFFFFFE）
export fn sar32(x: i32) i32 {
    return x >> 3;
}

// 8 位（n=1 走同一条模板）：-16 >> 2 = -4（逻辑右移会得 0x3C）
export fn sar8(x: i8) i8 {
    return x >> 2;
}
