//! M1 验收用例：u8 参数（SDCC ABI）+ u8 返回（DPL）。
export fn add(a: u8, b: u8) u8 {
    return a +% b;
}
