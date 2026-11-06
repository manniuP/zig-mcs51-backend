//! `const` 表：值进**代码段**（`.db`），读用 `movc a,@a+dptr`。
//! 这是 8051 上「查表」的标准姿势 —— XRAM 掉电即失，没人会去装载初值。

const BYTES: [8]u8 = .{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
const WORDS: [4]u16 = .{ 0x1122, 0x3344, 0x5566, 0x7788 };

// 常量下标：折成「_sym + off」的一次 movc
export fn cget2() u8 {
    return BYTES[2];
}

// 运行期下标（scale=1）
export fn cgeti(i: u8) u8 {
    return BYTES[i];
}

// u16 元素（scale=2，小端：0x1122 存成 22 11）
export fn wgeti(i: u8) u16 {
    return WORDS[i];
}

// ---- 多维 const 表：tbl[i][j]（第二维下标在运行期，链式加到 DPTR 上）----
// 4 行 × 4 列，值是 10*行+列，读出来能立刻看出行列有没有串。
const GRID: [4][4]u8 = .{
    .{ 0x00, 0x01, 0x02, 0x03 },
    .{ 0x10, 0x11, 0x12, 0x13 },
    .{ 0x20, 0x21, 0x22, 0x23 },
    .{ 0x30, 0x31, 0x32, 0x33 },
};

// 两维都在运行期：地址 = _GRID + i*4 + j
export fn g2(i: u8, j: u8) u8 {
    return GRID[i][j];
}

// 行运行期、列常量：地址 = _GRID + i*4 + 2
export fn g2c(i: u8) u8 {
    return GRID[i][2];
}

// 行常量、列运行期：地址 = _GRID + 3*4 + j
export fn g2r(j: u8) u8 {
    return GRID[3][j];
}