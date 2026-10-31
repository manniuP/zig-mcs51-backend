//! mcs2 的 UART 演示（51，全部内联在 main，无调用、无位操作）。
//! 后端目前还没有 and/or/位测试/call，所以：初始化用「常量整写 SFR」，
//! 发送用「写 SBUF + 固定延时」代替查 TI。跑完 7 个字符返回，由启动代码兜住。
const SCON: *volatile u8 = @ptrFromInt(0x98);
const SBUF: *volatile u8 = @ptrFromInt(0x99);
const TMOD: *volatile u8 = @ptrFromInt(0x89);
const TH1: *volatile u8 = @ptrFromInt(0x8D);
const TL1: *volatile u8 = @ptrFromInt(0x8B);
const TCON: *volatile u8 = @ptrFromInt(0x88);
const AUXR: *volatile u8 = @ptrFromInt(0x8E);
const P3M0: *volatile u8 = @ptrFromInt(0xB2);
const P3M1: *volatile u8 = @ptrFromInt(0xB1);

inline fn delay1ms() void {
    var i: u8 = 0;
    while (i < 200) : (i += 1) {
        var j: u8 = 0;
        while (j < 200) : (j += 1) {}
    }
}

export fn main() void {
    P3M1.* = 0x00;
    P3M0.* = 0x02;
    TMOD.* = 0x20;
    AUXR.* = 0x40;
    // 9600 @ 24MHz: 65536 - 24000000/4/9600 = 65411 = 0xFF83
    TH1.* = 0xFF;
    TL1.* = 0x83;
    TCON.* = 0x40;
    SCON.* = 0x40;

    SBUF.* = 'H';
    delay1ms();
    SBUF.* = 'E';
    delay1ms();
    SBUF.* = 'L';
    delay1ms();
    SBUF.* = 'L';
    delay1ms();
    SBUF.* = 'O';
    delay1ms();
    SBUF.* = 0x0D;
    delay1ms();
    SBUF.* = 0x0A;
    delay1ms();
}
