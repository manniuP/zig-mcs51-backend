//! **运行期指针做基址**：`p[i]` / `p[i] = v`，p 是**参数**（运行期才知道的地址）。
//! Zig 形状：参数 p 先被存进局部槽，再 load 回来做 ptr_cast → 运行期基址必须能穿过
//! 「arg → 局部槽 → load → ptr_cast → 下标」整条链，否则只能支持常量基址。
//!
//! 用例一律「写后读」：ucsim 的 xdata 初值不保证是 0，不能假设。

export fn pprt(p: [*]u8, i: u8, v: u8) u8 {
    p[i] = v;
    return p[i];
}

// scale=2：u16 元素，地址要 base + i*2（运行期基址 + 缩放）
export fn pu16(p: [*]u16, i: u8, v: u16) u16 {
    p[i] = v;
    return p[i];
}

// 运行期指针 + 二维下标：p[i][j]（基址运行期，两维都是运行期）
export fn p2d(p: *[4][8]u8, i: u8, j: u8, v: u8) u8 {
    p[i][j] = v;
    return p[i][j];
}
