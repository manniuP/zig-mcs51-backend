//! 全局数组（**符号基址**）：地址由链接器定，发射为 `mov dptr,#_sym`。
//! 与 `@ptrFromInt` 的常量基址互补；用例写-读自证（全局变量的初值不保证被装载）。

var tbl: [4]u16 = .{ 0x1111, 0x2222, 0x3333, 0x4444 };
var byt: [4]u8 = .{ 0x11, 0x22, 0x33, 0x44 };

// 常量下标：折成「_sym + k*scale」的一次访问
export fn symconst(v: u16) u16 {
    tbl[2] = v;
    return tbl[2];
}

// 运行期下标 + u16 元素（scale=2）
export fn symrt(i: u8, v: u16) u16 {
    tbl[i] = v;
    return tbl[i];
}

// u8 数组（scale=1）
export fn symb(i: u8, v: u8) u8 {
    byt[i] = v;
    return byt[i];
}

// 相邻两元素（符号基址 + scale=2，邻元素不得互相覆盖）
export fn sympair(i: u8, a: u16, b: u16) u16 {
    tbl[i] = a;
    tbl[i + 1] = b;
    return tbl[i] +% tbl[i + 1];
}