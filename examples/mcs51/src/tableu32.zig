//! 运行期下标 + **4 字节元素**（scale=4）：单独一个模块——mcs2 每个函数一块静态 DSEG，
//! 6 个函数就把 80 B 的内部 RAM 撑爆（实测 t16pair+t8pair+t32rt+t32pair 要 96 B）。
//! 用例写-读自证，不依赖 xdata 初值。

const T32: *volatile [8]u32 = @ptrFromInt(0x8400);

export fn t32rt(i: u8, v: u32) u32 {
    T32[i] = v;
    return T32[i];
}

// 相邻两个 32 位元素：既验 scale=4 的步长，也验元素内 4 字节的 base+k 偏移
export fn t32pair(i: u8, a: u32, b: u32) u32 {
    T32[i] = a;
    T32[i + 1] = b;
    return T32[i] +% T32[i + 1];
}
