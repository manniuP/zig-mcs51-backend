//! U2：位测试（jb/jnb）。
//! 用 SCON(0x98) 的 TI 位（SCON.1 → 位地址 0x99）模拟「置位-轮询-清零」。
const SCON: *volatile u8 = @ptrFromInt(0x98);

export fn bitpoll(n: u8) u8 {
    var cnt: u8 = 0;
    var i: u8 = 0;
    while (i < n) : (i += 1) {
        SCON.* = 0x02;                          // 置 TI
        if ((SCON.* & 0x02) != 0) cnt +%= 1;     // → jb 0x99
        SCON.* = 0x00;                          // 清 TI
    }
    return cnt;
}

export fn bitclear(n: u8) u8 {
    var cnt: u8 = 0;
    var i: u8 = 0;
    while (i < n) : (i += 1) {
        SCON.* = 0x00;
        if ((SCON.* & 0x02) == 0) cnt +%= 1;     // → jnb 0x99
    }
    return cnt;
}