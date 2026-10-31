//! 多字节（u16）：固定模板 = clr c + addc/subb 逐字节。
//! ABI：u16 参数/返回值走 DPL(低)/DPH(高)。
export fn u16add(a: u16, b: u16) u16 {
    return a +% b;
}

export fn u16sub(a: u16, b: u16) u16 {
    return a -% b;
}

// 进位链：低字节溢出必须进到高字节（0x00FF + x，x=1 → 0x0100）
export fn u16carry(x: u8) u16 {
    var a: u16 = 0x00FF;
    a +%= x;
    return a;
}
// 多字节左移：低字节的进位必须进到高字节（0x0080 << 1 = 0x0100）
export fn u16shl(x: u8) u16 {
    var a: u16 = 0x0080;
    a <<= 1;
    a +%= x;
    return a;
}

// 多字节右移：高字节的位要落到低字节（0x0100 >> 1 = 0x0080）
export fn u16shr(x: u8) u16 {
    var a: u16 = 0x0100;
    a >>= 1;
    a +%= x;
    return a;
}
// u32（4 字节）：参数/返回按 SDCC 约定走 DPL/DPH/B/A，第 2 个参数进 PARM_2 起
export fn u32add(a: u32, b: u32) u32 {
    return a +% b;
}

// 4 字节进位链：0x0000FFFF + x（x=1 → 0x00010000）
export fn u32carry(x: u8) u32 {
    var a: u32 = 0x0000FFFF;
    a +%= x;
    return a;
}