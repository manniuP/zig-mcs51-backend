//! 像真程序那样用 mcs2：**函数指针表 + 运行时填表 + UART 输出**。
//! 不是微用例：main 里建表、按表分派、算完把结果打出去，循环跑。
//! 目标：AI8051U-34K64，8 位模式，UART1 → P3.0/P3.1，Timer2 1T，40 MHz @ 115200。
//! 有意写成「真代码会有的样子」：inline 的 UART 小工具 + 三个命令处理函数 + 分派表。

const SCON: *volatile u8 = @ptrFromInt(0x98);
const SBUF: *volatile u8 = @ptrFromInt(0x99);
const AUXR: *volatile u8 = @ptrFromInt(0x8E);
const T2H: *volatile u8 = @ptrFromInt(0xD6);
const T2L: *volatile u8 = @ptrFromInt(0xD7);
const P3M0: *volatile u8 = @ptrFromInt(0xB2);
const P3M1: *volatile u8 = @ptrFromInt(0xB1);
const P_SW1: *volatile u8 = @ptrFromInt(0xA2);
const IAP_CONTR: *volatile u8 = @ptrFromInt(0xC7);

// 「自定义指令自动下载」的固件侧：串口收到**任何**字节就软复位进 ISP。
// AiCube 勾上那个选项后会先按用户波特率发一串自定义指令（默认 7F 7F 7F A5 7F），
// 固件认到就把 SWBS|SWRST 写进 IAP_CONTR → 复位后由 ISP 引导接管，不用拔插 USB。
// 只认「有字节」而不是某个魔法字：下载波特率可能与用户波特率不同，收到的是乱码。
inline fn isp_watch() void {
    if ((SCON.* & 0x01) != 0) {   // RI：收到字节
        _ = SBUF.*;               // 读走（硬件清 RI）
        IAP_CONTR.* = 0x60;       // SWBS=1 从 ISP 区启动 + SWRST=1 软复位
        while (true) {}           // 等芯片复位
    }
}

// 命令分派表（地址运行时填：全局初值现在不会被装载）
var cmdtab: [3]u16 = undefined;

// 固件版本标记（烧一次换一个字符，用来肉眼确认这次真的烧进去了）
const VERSION: u8 = 2;

// ---- 三个「命令」：u8 -> u8 ----
fn cmd_add(x: u8) u8 {
    return x +% 0x11;
}

fn cmd_triple(x: u8) u8 {
    const w: u16 = @as(u16, x) *% 3;   // 处理函数里照样能有多字节运算
    return @truncate(w);
}

fn cmd_halve(x: u8) u8 {
    return x >> 1;
}

// ---- UART 小工具（普通函数：inline 会把槽都算到 main 头上，main 就爆 DSEG 了） ----
fn putc(c: u8) void {
    SBUF.* = c;
    while ((SCON.* & 0x02) == 0) {}
    SCON.* &= ~@as(u8, 0x02);
}

inline fn hexdigit(v: u8) u8 {
    var d: u8 = '0' +% v;
    if (v >= 10) {
        d = 'A' +% (v -% 10);
    }
    return d;
}

fn putbyte(v: u8) void {
    putc(hexdigit(v >> 4));
    putc(hexdigit(v & 0x0F));
}

export fn main() void {
    P3M1.* = 0x00;      // P3.1 不设高阻
    P3M0.* = 0x02;      // P3.1(TXD) 推挽
    P_SW1.* &= 0x3F;    // S1_S = 00 → UART1 走 P3.0/P3.1
    SCON.* = 0x50;      // 模式1 + REN=1（要收字节才能被「自定义指令」叫去下载）
    // AUXR：S1ST2(bit0)=1 串口1 选 Timer2 + T2x12(bit2)=1 1T + T2R(bit4)=1 启动
    // 少写任何一位都不出字符：bit0 漏了没有波特率，bit4 漏了 Timer2 不走。
    AUXR.* = 0x15;
    T2H.* = 0xFF;       // 40 MHz/115200 → 0xFFA9
    T2L.* = 0xA9;

    cmdtab[0] = @truncate(@intFromPtr(&cmd_add));
    cmdtab[1] = @truncate(@intFromPtr(&cmd_triple));
    cmdtab[2] = @truncate(@intFromPtr(&cmd_halve));
    // 版本标记：改这个再烧一次，串口上能直接看出「新固件真的进来了」
    putc('A');
    putc('P');
    putc('P');
    putc(VERSION);
    putc(0x0D);
    putc(0x0A);

    var i: u8 = 0;
    while (true) {
        isp_watch();
        const fp: *const fn (u8) u8 = @ptrFromInt(cmdtab[i]);
        const r: u8 = fp(0x34);
        putc('0' +% i);
        putc('v');
        putc(VERSION);      // 每行都带版本，烧没烧进去一眼就看出来
        putc(' ');
        putbyte(r);
        putc(0x0D);
        putc(0x0A);
        i +%= 1;
        if (i >= 3) {
            i = 0;
        }
        var d: u8 = 0;
        while (d < 200) : (d += 1) {
            var e: u8 = 0;
            while (e < 200) : (e += 1) {}
        }
    }
}