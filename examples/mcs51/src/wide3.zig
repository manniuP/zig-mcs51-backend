//! 宽**局部量**：`var x: u16` / `var x: u32` 必须真的占 2/4 个槽。
//! （曾因 `.alloc` 的类型是 `*T` 而只分到 1 个槽，之后 2 字节 store 把相邻局部量踩掉。）

export fn wloc1(a: u16, b: u16) u16 {
    var x: u16 = a;
    var y: u16 = b;
    y +%= 1;
    x +%= y;   // 0x1234 + (0x0020 + 1) = 0x1255
    return x;
}

export fn wloc2(a: u16, b: u16) u32 {
    var x: u32 = a;
    var y: u32 = b;
    y +%= 1;
    x +%= y *% 0x10000;   // 0x1234 + 0x00030000 = 0x00031234
    return x;
}