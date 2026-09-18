//! mcs251.zig —— AI8051U / MCS-251 底层硬件访问宏（纯 Zig，comptime 生成内联汇编）。
//!
//! 用途：封装 Zig 里不方便直接写的操作——SFR 直址、SFR 位操作、以及各数据空间
//! （`data` / `xdata` / `idata`）的手动访问。所有地址/掩码/位号都是 **comptime 常量**，
//! 直接拼进汇编文本，因此不依赖 inline asm 的操作数支持。
//!
//! 依赖编译器：mcs251 后端需支持 `asm volatile ("...")`（无操作数）与 `inline fn` 内联。
//!
//! ## 安全性 / 检查（重要）
//!
//! - **编译期检查仍在**：参数是 `comptime u8` / `comptime u3`，类型与范围由 Zig 编译期检查
//!   （如位号必须 0–7、地址必须装得下 `u8`）；写错立即编译失败。
//! - **运行期/内存安全检查不适用**：`@ptrFromInt(addr)` 是**无检查**的地址转换，
//!   本后端也不生成运行时安全检查；`asm` 文本对 Zig 透明（只有 `sdas251` 查语法）。
//!   地址/寄存器是否正确由程序员负责。
//! - 本质：这些宏操作的是**指向绝对地址（SFR / 硬件）的指针**，是 Zig 的 unsafe 逃逸口；
//!   普通变量的别名/越界/初始化保证在这里**不适用**。
//! - 建议：一律用 `*volatile`（本库已如此，防止被优化/重排）；地址保持 `comptime` 常量；
//!   不要把这类指针存进变量（会退化为普通 24 位指针，且丢失固定地址代码生成）。
//!
//! ## 用法示例
//!
//! ```zig
//! const m = @import("mcs"); // 构建时加：--dep mcs -Mmcs=<仓库>/lib/mcs251.zig
//!
//! fn blinkInit() void {
//!     m.sfrAnd(0x91, 0xfd); // P1M1.1 = 0
//!     m.sfrOr(0x92, 0x02); // P1M0.1 = 1  -> P1.1 推挽输出
//! }
//!
//! fn step() void {
//!     m.bitClr(0x90, 1); // P1.1 = 0，LED 亮
//!     m.nop();
//!     m.bitSet(0x90, 1); // P1.1 = 1，LED 灭
//! }
//!
//! fn readP11() u1 {
//!     return @intCast(m.sfrPtr(0x90).* & 0x02); // 读 P1.1（字节 + 掩码）
//! }
//!
//! fn writeSpaces() void {
//!     m.dataWrite(0x30, 0x5a); // data[0x30] = 0x5a（直接寻址）
//!     m.xdataWrite(0x0100, 0xaa); // xdata[0x0100] = 0xaa（MOVX）
//!     m.idataWrite(0x40, 0x33); // idata[0x40] = 0x33（@R0 间接）
//! }
//! ```

// ---------------------------------------------------------------------------
// 目标架构
// ---------------------------------------------------------------------------

const builtin = @import("builtin");

/// 目标为 8 位 MCS-51 时为 true。仅影响位操作数的汇编语法：
/// sdas8051 用 `addr^bit`，sdas251（mcs251）用 `addr.bit`。
const is_mcs51 = builtin.cpu.arch == .mcs51;

// ---------------------------------------------------------------------------
// 冷热 / 放置 / 优化等级标签（linksection 字符串）：可用空格组合，如
// `linksection(m.xdata ++ " " ++ m.O5)`。无放置标签→编译器自决；无等级→默认 O3。
// ---------------------------------------------------------------------------

// 放置：按速度 `data`(直址) > `idata`(@r0) > `edata`(@dptr) > `xdata`(@dpx) > `exdata`(片外)。
pub const data = ".data";
pub const idata = ".idata";
pub const edata = ".edata";
pub const xdata = ".xdata";
pub const exdata = ".exdata";

// 优化等级（与 GCC 对齐）：`O0`–`O3` 为优化力度（偏速度）、`Ofast` 最快、`Os` 偏体积；
// 未标注时默认 `O3`（跟随全局 `-O*`）。
pub const O0 = ".O0";
pub const O1 = ".O1";
pub const O2 = ".O2";
pub const O3 = ".O3";
pub const Ofast = ".Ofast";
pub const Os = ".Os";

// 兼容旧名（等价组合）。
pub const hot = ".data.O0";
pub const warm = ".idata.O3";
pub const cold = ".cold";

// ---------------------------------------------------------------------------
// 内部：comptime 十六进制/十进制字符
// ---------------------------------------------------------------------------

fn hex2(comptime v: u8) [2]u8 {
    const dgt = "0123456789abcdef";
    return .{ dgt[v >> 4], dgt[v & 0x0f] };
}

fn hex4(comptime v: u16) [4]u8 {
    const dgt = "0123456789abcdef";
    return .{ dgt[(v >> 12) & 0xf], dgt[(v >> 8) & 0xf], dgt[(v >> 4) & 0xf], dgt[v & 0x0f] };
}

fn dec1(comptime v: u3) [1]u8 {
    return .{@as(u8, '0') + v};
}

// ---------------------------------------------------------------------------
// SFR / 位操作
// ---------------------------------------------------------------------------

/// 空操作 `nop`。
pub inline fn nop() void {
    asm volatile ("nop");
}

// ---------------------------------------------------------------------------
// UART1（P3.0/P3.1，阻塞式发送）
// ---------------------------------------------------------------------------

/// 初始化 UART1：模式1、仅发送，波特率发生器用 Timer1（1T、16 位自动重载），引脚 P3.0/P3.1。
/// `fosc` 为系统时钟（Hz），`baud` 为波特率。
///
/// 示例：`uartInit(40_000_000, 9600);`
pub inline fn uartInit(comptime fosc: u32, comptime baud: u32) void {
    sfrWrite(0x98, 0x40); // SCON = 模式1（8 位 UART），REN=0
    sfrAnd(0x8e, ~@as(u8, 0x01)); // AUXR.0=0  S1 波特率用 Timer1
    sfrOr(0x8e, 0x40); // AUXR.6=1  Timer1 1T
    sfrAnd(0x89, 0x0f); // TMOD：Timer1 模式0（16 位自动重载）
    const reload: u16 = @intCast(65536 - fosc / 4 / baud);
    sfrWrite(0x8d, @intCast((reload >> 8) & 0xff)); // TH1
    sfrWrite(0x8b, @intCast(reload & 0xff)); // TL1
    bitSet(0x88, 6); // TR1 = TCON.6
    sfrAnd(0xa2, 0x3f); // P_SW1：UART1 选 P3.0/P3.1
    sfrAnd(0xb1, ~@as(u8, 0x02)); // P3M1.1=0
    sfrOr(0xb2, 0x02); // P3M0.1=1  P3.1 推挽输出
}

/// 阻塞发送一个字节（等 TI，再清 TI）。
///
/// 注意：**非 `inline`**——轮询循环只生成一份，调用点共享，避免每个字节把整段
/// 循环内联展开（尺寸问题）。带 `comptime` 字面量的 `uartPuts` 仍是 `inline for`，
/// 逐字符发出 `mov dpl,#c; ecall`。
pub fn uartPutc(c: u8) void {
    sfrPtr(0x99).* = c; // SBUF
    while ((sfrPtr(0x98).* & 0x02) == 0) {} // 等 TI（SCON.1）
    sfrAnd(0x98, ~@as(u8, 0x02)); // 清 TI
}

/// 发送字符串（`comptime` 字面量，逐字符内联展开）。
///
/// 示例：`uartPuts("\r\nOK\r\n");`
pub inline fn uartPuts(comptime s: []const u8) void {
    inline for (s) |c| uartPutc(c);
}

/// 打印一个字节为两位十六进制（如 `0xA1` → "a1"）。
/// 非 `inline`：`hexDigit` 的分支只生成一份，调用点共享（尺寸考虑，同 `uartPutc`）。
pub fn uartPutHex2(v: u8) void {
    uartPutc(hexDigit(v >> 4));
    uartPutc(hexDigit(v & 0x0f));
}

/// 半字节 → 十六进制字符（避免用运行期下标索引字符串——后端不支持）。
inline fn hexDigit(n: u8) u8 {
    return if (n < 10) @as(u8, '0') + n else @as(u8, 'a') + (n - 10);
}

// COBS 编码与轻量日志帧已抽成独立、平台无关的库：见 `lib/cobs/`（Zig 接口 `cobs.zig`、
// C 接口 `cobs.h`/`cobs.c`）。本文件只保留 AI8051U/MCS-251 的硬件访问宏与 UART。

/// 写 SFR：`mov dir8,#imm`。`addr` 为 SFR 字节地址（0x80–0xFF）。
///
/// 示例：`sfrWrite(0x90, 0xfe); // P1 = 0xfe`
pub inline fn sfrWrite(comptime addr: u8, comptime val: u8) void {
    asm volatile ("mov 0x" ++ hex2(addr) ++ ",#0x" ++ hex2(val));
}

/// SFR 按位或：`orl dir8,#imm`（读-改-写，一条指令）。
///
/// 示例：`sfrOr(0x92, 0x02); // P1M0 |= 0x02`
pub inline fn sfrOr(comptime addr: u8, comptime mask: u8) void {
    asm volatile ("orl 0x" ++ hex2(addr) ++ ",#0x" ++ hex2(mask));
}

/// SFR 按位与：`anl dir8,#imm`（读-改-写）。
///
/// 示例：`sfrAnd(0x91, 0xfd); // P1M1 &= ~0x02`
pub inline fn sfrAnd(comptime addr: u8, comptime mask: u8) void {
    asm volatile ("anl 0x" ++ hex2(addr) ++ ",#0x" ++ hex2(mask));
}

/// 位置 1：`setb addr.bit`。可位寻址：SFR 位（字节地址 8 的倍数）或 RAM 0x20–0x2F。
///
/// 示例：`bitSet(0x90, 1); // P1.1 = 1`；`bitSet(0x21, 3); // RAM 0x21.3 = 1`
pub inline fn bitSet(comptime addr: u8, comptime bit: u3) void {
    asm volatile ("setb 0x" ++ hex2(addr) ++ (if (is_mcs51) "^" else ".") ++ dec1(bit));
}

/// 位清 0：`clr addr.bit`。
///
/// 示例：`bitClr(0x90, 1); // P1.1 = 0（LED 亮）`
pub inline fn bitClr(comptime addr: u8, comptime bit: u3) void {
    asm volatile ("clr 0x" ++ hex2(addr) ++ (if (is_mcs51) "^" else ".") ++ dec1(bit));
}

/// 位取反：`cpl addr.bit`。
///
/// 示例：`bitCpl(0x90, 1); // P1.1 翻转`
pub inline fn bitCpl(comptime addr: u8, comptime bit: u3) void {
    asm volatile ("cpl 0x" ++ hex2(addr) ++ (if (is_mcs51) "^" else ".") ++ dec1(bit));
}

/// 取 SFR/RAM 字节的指针（`data` 直址区 0x00–0xFF），可读可写。
///
/// `addr` 为 `comptime` 常量时，解引用走 **direct**（`mov a,dir8`/`mov dir8,a`）；
/// 读某一位：`@intCast(sfrPtr(0x90).* & 0x02)`。
///
/// 示例：`sfrPtr(0x90).* = 0xfe;` / `const x = sfrPtr(0x90).*;`
pub inline fn sfrPtr(comptime addr: u8) *volatile u8 {
    return @ptrFromInt(addr);
}

// ---------------------------------------------------------------------------
// 数据空间
// ---------------------------------------------------------------------------

/// 写 `data`（片内直接 RAM 0x00–0x7F）：`mov dir8,#imm`。
///
/// 示例：`dataWrite(0x30, 0x5a);`
pub inline fn dataWrite(comptime addr: u8, comptime val: u8) void {
    asm volatile ("mov 0x" ++ hex2(addr) ++ ",#0x" ++ hex2(val));
}

/// 写 `xdata`（外部/扩展 RAM，16 位地址）：`mov dptr,#addr; mov a,#val; movx @dptr,a`。
///
/// 示例：`xdataWrite(0x0100, 0xaa);`
pub inline fn xdataWrite(comptime addr: u16, comptime val: u8) void {
    asm volatile ("mov dptr,#0x" ++ hex4(addr) ++ "\nmov a,#0x" ++ hex2(val) ++ "\nmovx @dptr,a");
}

/// 写 `idata`（间接片内 RAM，@Ri 访问）：`mov r0,#addr; mov @r0,#val`。
///
/// 注：只提供写；读需把 A 回传，当前 inline asm 不支持操作数。
///
/// 示例：`idataWrite(0x40, 0x33);`
pub inline fn idataWrite(comptime addr: u8, comptime val: u8) void {
    asm volatile ("mov r0,#0x" ++ hex2(addr) ++ "\nmov @r0,#0x" ++ hex2(val));
}

/// 取 `data` 空间指针（0x00–0x7F），走 direct 读写。
///
/// 示例：`dataPtr(0x30).* += 1;`
pub inline fn dataPtr(comptime addr: u8) *volatile u8 {
    return @ptrFromInt(addr);
}

/// 取 `xdata` 空间指针（≥0x100），走 MOVX 读写。
///
/// 示例：`xdataPtr(0x0100).* = 0xaa;`
pub inline fn xdataPtr(comptime addr: u16) *volatile u8 {
    return @ptrFromInt(addr);
}
