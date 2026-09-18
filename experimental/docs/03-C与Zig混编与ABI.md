# 03 C 与 Zig 混编与 ABI

## 1. 推荐分工

| 部分 | 用谁 | 原因 |
| --- | --- | --- |
| 硬件/SFR 操作（Px、定时器、UART…） | **C + STC HAL** | `lib/stc-hal/` 已是 SDCC 可编译的官方库；C 对 SFR/位操作最直接 |
| 纯算法/逻辑（图案、换算、状态机） | **Zig** | 由自举后端编译；逻辑与硬件解耦，接口简单 |

当前 Zig 后端对 `sfr`/`bit` 地址空间的直接访问能力有限，因此**让 Zig 只做
纯计算、通过函数参数/返回值与 C 交互** 是最稳妥、已验证可行的方式。

## 2. 符号命名

- C 的全局符号在汇编里带 `_` 前缀：`main` → `_main`。
- Zig 的 `export fn foo` 也生成 `_foo`。

所以二者直接互相引用即可，无需 `extern` 名字修饰处理。

## 3. MCS-51（8051 兼容模式）ABI

本仓库后端对 MCS-51 **单字节标量**的参数/返回与 SDCC 默认 ABI 一致：

- **参数**：放在 `DPL`；
- **返回值**：放在 `DPL`。

实测对照（`export fn led_next(x: u8) u8`）：

Zig 后端产物：

```asm
_led_next:
        mov a,dpl          ; 取参数
        ...
        mov dpl,a          ; 写返回值
        ret
```

SDCC 调用方：

```asm
        mov dpl, #0x10     ; 传参
        ljmp _led_next     ; 调用（尾调用）
```

两者严丝合缝。因此**接口刻意只用「单字节参数 + 单字节返回」**，
既简单又免去额外约定。

更宽的标量（2~4 字节）按 ABI 寄存器组 `DPL/DPH/B/A` 摆放；但**多参数的
寄存器/栈分配在 SDCC 与自举后端之间尚未系统验证**，建议：

- 优先 0~1 个参数；
- 必须多参时，先写一个一致性测试，用 `*.map` / `*.lst` 核对寄存器与栈偏移。

## 4. MCS-251 ABI（rev2）

按 `sdcc-c251/doc/mcs251/abi.md` 约定：

- 首个标量参数/返回：`DPL/DPH/B/A`；
- 其余标量参数：由调用者压硬件栈，被调方按 `-(2 + Σsize)` 读取；
- 标量大端；
- 指针 3 字节（xdata/far/code/generic）；
- 互操作时各编译单元统一使用 `--stack-auto` / `__reentrant`。

Zig 后端的 MCS-251 支持范围见 [06-常见问题与限制](06-常见问题与限制.md)。

## 5. 双向调用写法

### 5.1 C 调 Zig（示例工程采用）

Zig 侧：

```zig
// led.zig
export fn led_next(cur: u8) u8 {
    const had_high: bool = (cur & 0x80) != 0;
    var next: u8 = cur +% cur;
    if (had_high) next |= 1;
    if (next == 0) next = 1;
    return next;
}
```

C 侧：

```c
/* main.c */
extern u8 led_next(u8 cur);   /* 名字与 Zig 的 export fn 对应 */
...
led = led_next(led);
```

### 5.2 Zig 调 C

C 侧提供实现（可见符号）：

```c
u8 board_led_read(void) { return P1; }
```

Zig 侧声明并调用：

```zig
extern fn board_led_read() u8;
export fn step() u8 { return board_led_read(); }
```

链接时把该 C 的 `.rel` 与 Zig 的 `.rel` 一起交给 `sdcc`/`sdld` 即可。

## 6. 注意事项

- 参数/返回类型选**定长标量**（`u8`/`u16`/`u32`），避免跨语言传结构体、切片、
  指针 —— 这些在自举后端的支持尚不完整。
- MCS-251 的 `usize` 是 24 位，**不能**作为 MCS 调用约定的函数参数/返回
  （会被前端的 extern 校验拒绝）；互操作接口请用显式定长整数。
- 变量名、函数名保持 ASCII；中文只放注释。
