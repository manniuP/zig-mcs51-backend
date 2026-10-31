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
const P_SW1: *volatile u8 = @ptrFromInt(0xA2);

inline fn delay1ms() void {
    var i: u8 = 0;
    while (i < 255) : (i += 1) {
        var j: u8 = 0;
        while (j < 255) : (j += 1) {}
    }
}

export fn main() void {
    // UART1 切到 P3.6(RXD)/P3.7(TXD)：P_SW1 的 S1_S = 01（STC 官方 PortSwitch）
    P_SW1.* = 0x40;
    P3M1.* = 0x00;
    P3M0.* = 0x80;   // P3.7(TXD) 推挽输出
    TMOD.* = 0x20;
    AUXR.* = 0x40;
    // STC8H 是 8051 核：Timer1 模式2 = 8 位自动重载，baud = FOSC/(32*(256-TH1))（1T）
    // 9600 @45.1584MHz: 256 - 45158400/(32*9600) = 109 = 0x6D
    TH1.* = 0x6D;
    TL1.* = 0x6D;
    TCON.* = 0x40;
    SCON.* = 0x40;

    while (true) {
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
}
