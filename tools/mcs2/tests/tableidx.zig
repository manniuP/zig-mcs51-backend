//! 运行期下标 + **多字节元素**：元素地址 = base + i*scale（u16 → 2）。
//! 用例设计成「写-读自证」，不依赖 xdata 初值（ucsim 的 xdata 不是 0，踩过）。
//! 基址目前必须是固定地址（@ptrFromInt）；全局数组符号寻址是下一步。

const T16: *volatile [8]u16 = @ptrFromInt(0x8200);
const T8: *volatile [8]u8 = @ptrFromInt(0x8300);

// 写 v 到 T16[i] 再读回：等于 v 说明 scale=2 的存/取都对
export fn t16rt(i: u8, v: u16) u16 {
    T16[i] = v;
    return T16[i];
}

// 邻元素不受影响（i 与 i+1 不重叠，验证 scale 不是 1）
export fn t16pair(i: u8, a: u16, b: u16) u16 {
    T16[i] = a;
    T16[i + 1] = b;
    return T16[i] +% T16[i + 1];
}

// u8 表（scale=1）对照
export fn t8rt(i: u8, v: u8) u8 {
    T8[i] = v;
    return T8[i];
}
