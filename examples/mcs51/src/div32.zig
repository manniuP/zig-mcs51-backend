//! 32 位除法：0x00012345 / 0x100 = 0x123 余 0x45。

export fn u32div(a: u32, b: u32) u32 {
    return a / b;
}

export fn u32rem(a: u32, b: u32) u32 {
    return a % b;
}
