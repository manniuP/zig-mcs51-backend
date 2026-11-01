//! 位运算常用形态：移位（u8，编译期次数）与单比特置位/清零。
//! `setbit`/`clrbit` 原本拿 SCON 做实验，结果**外壳正是用 SCON 发字符**，真机上互相干扰
//! （打印丢一条，ucsim 里却看不出）。改成对 **0x20（0x20–0x2F 是位可寻址 RAM，位地址 0x00）**
//! 做同样的 setb/clr —— 指令形态完全一样，而且不再碰串口控制寄存器。
const BITRAM: *volatile u8 = @ptrFromInt(0x20);

// << ：0x41 << 2 = 0x04（高两位溢出丢弃）
export fn shl2(a: u8) u8 {
    return a << 2;
}

// >> ：0xFF >> 3 = 0x1F
export fn shr3(a: u8) u8 {
    return a >> 3;
}

// 单比特置位 → setb 0x01（0x20 的第 1 位）
export fn setbit() u8 {
    BITRAM.* = 0x00;
    BITRAM.* |= 0x02;
    return BITRAM.*;
}

// 单比特清零 → clr 0x01
export fn clrbit() u8 {
    BITRAM.* = 0xFF;
    BITRAM.* &= ~@as(u8, 0x02);
    return BITRAM.*;
}