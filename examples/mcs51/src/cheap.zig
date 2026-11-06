// 反例：只有加减和位运算，每条指令本身 1～3 B。
//
// 两个同构函数即使重复，也不能被压成共享子程序：一次 lcall 就要 3 B，
// 加上 ret 1 B 和参数搬运，比被搬走的指令还贵。用例表里的 forbid_shared
// 会检查产物里没有 _mcs_sh_ 调用，防止「为了优化而变大」。
export fn cheap_a(a: u8, b: u8) u8 {
    return (a +% b) ^ 0x5A;
}

export fn cheap_b(a: u8, b: u8) u8 {
    return (a +% b) ^ 0x5A;
}
