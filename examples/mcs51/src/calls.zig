//! M2.5 内部调用：内部 ABI 复用 SDCC 边界 ABI（arg0→DPL/DPH/B/A，其余→PARM_2+）。
//! 所有值都住 DSEG 静态槽 → 调用不需要保存寄存器现场。

fn add8(a: u8, b: u8) u8 {
    return a +% b;          // b 走 _add8_PARM_2
}

fn triple16(x: u16) u16 {
    return x *% 3;          // x 走 DPL/DPH
}

export fn wide_mix(a: u32, b: u8) u32 {
    return a +% b;          // b 走 _wide_mix_PARM_2（arg0 占满 4 个寄存器）
}

// 8 位二参数调用 → u16 参数调用 → 结果
export fn chain(x: u8) u16 {
    const s = add8(x, 5);
    return triple16(@as(u16, s));
}

// 4 字节 arg0 + PARM_2 的 u8：验证 ABI 寄存器满载后溢出的位置
export fn chain32(x: u8) u32 {
    return wide_mix(0x12345600, x);
}
