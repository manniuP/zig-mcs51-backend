# 20 - 纯 Zig 定时器中断打印（Timer0 ISR + UART1）

> 结论：**可以**。示例 `examples/ai8051u_zig_t0print`，`xmake f --mcs_arch=mcs251; xmake build zigprint`
> → `t0print.ihx`。QEMU（机 `stc32g144k246`）与**真机 AI8051U-34K64**均已实测：UART1 每秒输出一行
> `t0\r\n`（真机 COM8@115200，行间隔实测 1.00s）。
> 对应 STC 的 C 版：Timer2 作波特率发生器 + Timer0 1ms 中断 + 在 ISR 里打印。

## 1. 关键坑（「定时器中断有问题」的根因）

本后端**没有** `interrupt` 调用约定。若 ISR 用普通 `export fn` 且在函数体里**直接写会产生栈帧的
Zig 代码**（局部变量/需要 spilled 值），后端会生成：

```
_t0_isr:                    ; 函数头 prologue
        add spx,#0x0014     ; 分配帧（N=20）
        ... 干活的 Zig 代码 ...
        push 0xe0 / push 0xd0 ... reti   ; 内联汇编里的 reti
        sub spx,#0x0014     ; 函数尾 epilogue（不可达！）
        eret
```

`reti` **跳过了尾部 `sub spx,#N`** → **每次中断 SPX 泄漏 N 字节**，跑一会儿栈就撞坏/死机。
（若函数体只有内联汇编、无局部量，后端不加帧，就不会有这个问题——`zigirq` 正是如此。）

## 2. 正确模式：无帧 ISR + `ecall` 到普通函数

ISR 只保留**无帧**的内联汇编，把逻辑放进普通 `export fn`（它有完整 prologue/epilogue + `ret`）：

```zig
var tick_ms: u16 = 0;

export fn on_t0() void {          // 普通函数：有帧、能调别的函数、会正常 ret
    tick_ms +%= 1;
    if (tick_ms == 1000) {
        tick_ms = 0;
        m.uartPuts("t0\r\n");     // 在中断里打印
    }
}

export fn t0_isr() void {         // ISR：无帧
    asm volatile (
        \\push 0xe0               // ACC
        \\push 0xd0               // PSW
        \\ecall _on_t0            // 调普通 Zig 函数
        \\pop 0xd0
        \\pop 0xe0
        \\reti
    );
}
```

生成结果（`t0print.asm`）验证：`_t0print_t0_isr` 直接 `push 0xe0`（**无 `add spx`**），
`_t0print_on_t0` 有 `add spx,#7 ... sub spx,#7; eret`。向量表在 `crt0.asm` 的 HOME 区
（Timer0 = `FF:000B` → `ejmp _t0_isr`），复位 `ljmp __start` 占 3 字节给 INT0 让位。

> 注意：`ecall` 的目标用**导出名** `_on_t0`（`export fn` 生成的 trampoline，内部体叫
> `_<file>_on_t0`）；用 `export` 保证它不被 DCE。

## 3. 初始化（与 STC C 对照）

- **UART1**（Timer2 作波特率发生器，115200@40MHz）：

  | STC C | Zig（`mcs251.zig` 宏） | 寄存器 |
  | --- | --- | --- |
  | `SCON=0x50` | `sfrWrite(0x98,0x50)` | SCON |
  | `AUXR|=0x01` | `sfrOr(0x8e,0x01)` | S1BRT：串口1 用 Timer2 |
  | `AUXR|=0x04` | `sfrOr(0x8e,0x04)` | T2x12：Timer2 1T |
  | `T2L=0xA9;T2H=0xFF` | `sfrWrite(0xd7,0xa9);sfrWrite(0xd6,0xff)` | 重载 0xFFA9 |
  | `AUXR|=0x10` | `sfrOr(0x8e,0x10)` | T2R：启动 Timer2 |
  | —— | `P3.1 推挽 + P_SW1 选 P3.0/P3.1` | `0xb1/0xb2/0xa2` |

- **Timer0**（1ms，1T，模式0=16 位自动重载）：

  | STC C | Zig | 寄存器 |
  | --- | --- | --- |
  | `AUXR|=0x80` | `sfrOr(0x8e,0x80)` | T0x12：1T |
  | `TMOD&=0xF0` | `sfrAnd(0x89,0xf0)` | 模式0 |
  | `TL0=0xC0;TH0=0x63` | `sfrWrite(0x8a,0xc0);sfrWrite(0x8c,0x63)` | 重载 0x63C0 |
  | `TF0=0;TR0=1` | `bitClr(0x88,5);bitSet(0x88,4)` | TCON |
  | `ET0=1;EA=1` | `bitSet(0xa8,1);bitSet(0xa8,7)` | IE |

- **不需要 `ES=1`**：本示例用查询发送（`uartPutc` 等 TI 再清 TI），无需 UART1 中断；
  `crt0.asm` 在 `FF:0023`（UART1）留了 `reti` 兜底。若确实要 UART 中断，把中断号 4 的 ISR 也加进
  向量表（间隔 8 字节）。

## 4. 其它注意

- ISR 只存了 `ACC/PSW`；`on_t0` 会用到 `A/R6/DPL` 等。若被中断的主线代码有活跃的 `R0–R7`，
  应把 `0x00–0x07` 也 `push/pop` 保存（本示例主线是空循环，故未保存）。
- `on_t0` 里打印是**阻塞**的（等 TI）。115200 下一个字节 ~87µs，`"t0\r\n"` 4 字节 ~350µs < 1ms，
  安全；要发长串请缩短或改为环形缓冲 + 主循环发送。
- 真机 AI8051U 需 `--code-loc 0xff0000`、I/O 先配 `PxM0/PxM1`、硬件选项 CPU=32-Bit；
  UART1 在 P3.1(P3.0)，需 USB-TTL 才能看输出。

## 5. 附：UART1 接收中断回环（`examples/ai8051u_zig_uart_echo`，`xmake build ziguart`）

同样的「无帧 ISR + `ecall`」模式，用在 UART1 中断（号 4，向量 `FF:0023`）上，实现回显。
**要处理连续突发**，需一个发送环形缓冲（否则上一字节没发完又写 `SBUF` 会丢字节）：

```zig
var ring: [64]u8 = undefined;
var r_head: u8 = 0; var r_tail: u8 = 0; var tx_busy: u8 = 0;

export fn on_uart() void {
    if ((m.sfrPtr(0x98).* & 0x02) != 0) {       // TI：发送完成
        m.sfrAnd(0x98, ~@as(u8, 0x02));
        if (r_head != r_tail) {                 // 有排队 → 续发
            m.sfrPtr(0x99).* = ring[r_tail]; r_tail +%= 1;
        } else tx_busy = 0;
    }
    if ((m.sfrPtr(0x98).* & 0x01) != 0) {       // RI：收到
        const b = m.sfrPtr(0x99).*;             // 读 SBUF
        m.sfrAnd(0x98, ~@as(u8, 0x01));         // 显式清 RI
        if (tx_busy == 0) { m.sfrPtr(0x99).* = b; tx_busy = 1; }  // 空闲 → 直接回
        else { const h = r_head +% 1; if (h != r_tail) { ring[r_head] = b; r_head = h; } } // 入队
    }
}
export fn uart_isr() void {                     // 无帧
    asm volatile ("push 0xe0\npush 0xd0\necall _on_uart\npop 0xd0\npop 0xe0\nreti");
}
```

初始化：`SCON=0x50`（模式1 + `REN=1`）、Timer2 波特率（同上）、`IE.ES=1`、`IE.EA=1`；
P3.0 保持准双向（RxD），P3.1 推挽（TxD）。

**坑 1**：某些仿真模型读 `SBUF` **不自动清 `RI`** → ISR 反复重入、把第一个字节狂刷；
显式 `anl SCON,#~1` 清 `RI`（与 STC 的 `RI=0` 一致）即可。真机 8051 读 SBUF 本来就会清 RI。
**坑 2**：非缓冲回显在突发下丢字节（实测 `Ai8051U`→`Ai805U`）——上面的环形缓冲解决。

实测：QEMU 与真机（COM8@115200）对 `hello` / `Ai8051U` / `0123456789abcdef` /
`The quick brown fox` 均原样回显。
