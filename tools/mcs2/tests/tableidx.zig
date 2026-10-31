//! 运行期下标 + **多字节元素**（u16 查表 / 函数指针表的读取基础）。
//! 元素地址 = base + i*scale，scale 由元素类型宽度决定（u16 → 2）。
//! 基址目前必须是固定地址（@ptrFromInt）；全局数组符号寻址是下一步。

const T16: *volatile [8]u16 = @ptrFromInt(0x8200);
const T8: *volatile [8]u8 = @ptrFromInt(0x8300);

export fn t16get(i: u8) u16 {
    return T16[i];
}

export fn t16set(i: u8, v: u16) void {
    T16[i] = v;
}

// u8 表（scale=1）作对照：不能因为加 scale 把老路径弄坏
export fn t8get(i: u8) u8 {
    return T8[i];
}
