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