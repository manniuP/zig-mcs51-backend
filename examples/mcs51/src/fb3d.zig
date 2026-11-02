//! **三维数组**：屏幕帧缓冲 `fb[page][row][col]`，元素是 u16 颜色（RGB565）。
//! 地址 = base + page*4096 + row*128 + col*2 —— 三个步长分别是 4096 / 128 / 2，
//! 正好覆盖「步长 > 255（必须走多维链）」「步长 = 128（乘 128 的进位）」「步长 = 2」三种情况。

const FB: *[2][32][64]u16 = @ptrFromInt(0x2000);
// 同一个缓冲的「一维视图」：用来交叉验证多维下标的步长算得对不对
const FLAT: *[4096]u16 = @ptrFromInt(0x2000);

export fn px(z: u8, y: u8, x: u8, c: u16) u16 {
    FB[z][y][x] = c;
    return FB[z][y][x];
}

// 交叉验证：多维下标写进去，再用「平面下标 = z*2048 + y*64 + x」读回来。
// 两条路径各算一遍地址，算错就对不上 → 期望 0。
export fn pxchk(z: u8, y: u8, x: u8, c: u16) u16 {
    FB[z][y][x] = c;
    const i: u16 = (@as(u16, z) * 2048) + (@as(u16, y) * 64) + x;
    return FLAT[i] ^ c;
}
// 全局三维数组（符号基址，不是 @ptrFromInt）：屏幕驱动更可能这么写
var gfb: [2][32][64]u16 = undefined;

export fn gpx(z: u8, y: u8, x: u8, c: u16) u16 {
    gfb[z][y][x] = c;
    return gfb[z][y][x];
}
