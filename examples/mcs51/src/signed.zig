//! 有符号（i8/i16/i32）：符号扩展 + 有符号比较。
//! 边界 ABI 与无符号一致（字节序 DPL/DPH/B/A、arg1+ 进 PARM_2 起），驱动不用变。
//! 注意：vreg 是「每函数一套 DSEG 槽」（M2.14 活跃期分析之前不做复用），
//! 所以每个测试文件只放 2-3 个函数，否则 8051 的 80 字节直址区装不下。

// i8 → i32 符号扩展 + 与 -1 的有符号比较（-5 < -1 成立，按无符号序会判反）
export fn sexcmp(x: i8) u8 {
    const a: i32 = x;
    const b: i32 = -1;
    if (a < b) return 1;
    return 0;
}

// i16 → i32 符号扩展：0x8000 (-32768) 必须扩成 0xFFFF8000，不是 0x00008000
export fn sex16(x: i16) i32 {
    const a: i32 = x;
    return a;
}
