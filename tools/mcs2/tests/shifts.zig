//! 位运算常用形态：移位（u8，编译期次数）与 SFR 单比特置位/清零。
const SCON: *volatile u8 = @ptrFromInt(0x98);

// << ：0x41 << 2 = 0x04（高两位溢出丢弃）
export fn shl2(a: u8) u8 {
    return a << 2;
}

// >> ：0xFF >> 3 = 0x1F
export fn shr3(a: u8) u8 {
    return a >> 3;
}

// SFR 置单个位 → setb 0x99（TI）
export fn setbit() u8 {
    SCON.* = 0x00;
    SCON.* |= 0x02;
    return SCON.*;
}

// SFR 清单个位 → clr 0x99
export fn clrbit() u8 {
    SCON.* = 0xFF;
    SCON.* &= ~@as(u8, 0x02);
    return SCON.*;
}