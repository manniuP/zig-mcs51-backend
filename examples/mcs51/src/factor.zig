// 重复复杂算法压缩的验收源。
//
// 三个导出函数的 16 位乘法展开块完全同构，后端应把它统计成同一个模板，
// 只发一份共享子程序（_mcs_sh_0），三处调用点改成 lcall。
// 这既守住「压缩后行为不变」，也守住「压缩确实发生」——用例表里的
// want_shared 会检查产物里的 lcall 数量，优化退化时验收会红。
export fn fac_a(a: u16, b: u16) u16 {
    return a *% b;
}

export fn fac_b(a: u16, b: u16) u16 {
    return a *% b;
}

export fn fac_c(a: u16, b: u16) u16 {
    return a *% b;
}
