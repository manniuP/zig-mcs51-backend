//! 多字节比较与位运算：u32 的 >/== 走跨 4 字节借位链；
//! and/or/not 是逐字节的，与宽度无关。

// 借位链跨 4 字节：a=0x00010000
export fn ucmp32(x: u32) u8 {
    const a: u32 = 0x00010000;
    if (a > x) return 1;
    if (a == x) return 2;
    return 3;
}

// 逐字节 and/or/not
export fn wbits(x: u32) u32 {
    const m: u32 = 0xFF00FF00;
    const r: u32 = (x & m) | 0x000000F0;
    return ~r;
}

// 有符号加减：位模式与无符号一致，验证 i32 的 ABI 走通
export fn i32add(a: i32, b: i32) i32 {
    return a +% b;
}
