# AI8051U 流水灯（C + Zig 混合工程）

本工程演示如何用 **C（STC AI8051U HAL 库）+ Zig（MCS 后端）** 共同构建一个可
烧录的流水灯固件，是 [docs/](README.md) 中「Zig + SDCC 混编」流程的完整落地示例。

> 源码在 `examples/ai8051u_blink/`，本说明文档统一收录在 `docs/`。

## 效果

- P1.0 ~ P1.7 接 8 个 LED，低电平点亮；
- 上电 P1.0 先亮，每 200ms 依次点亮下一位，到 P1.7 后回到 P1.0 循环。

## 工程结构

```
examples/ai8051u_blink/
  main.c        C 主程序：STC HAL 配置 P1、写 P1、调 delay_ms
  led.zig       Zig 逻辑：export fn led_next(u8) u8，返回下一个灯位
  build.ps1     构建脚本：C→rel，Zig→asm→rel，再链接成 ihx
```

（本说明文档在 `docs/10-工程-ai8051u_blink.md`。）

产物（构建后生成）：`blink.ihx`、`blink.map`，以及中间文件 `*.rel/.asm/.lst/...`。

## 依赖

- 本机 SDCC 4.5.20（`sdcc.exe` / `sdas8051.exe` / `sdld.exe`）；
- 预编译的 `compiler/zig-out/bin/zig.exe`（55MB，见 [01-环境准备](01-环境准备.md) 第 3 节）；
- 头文件 `include/` 与 STC HAL `lib/stc-hal/`（脚本自动引用）。

准备步骤见 [01-环境准备.md](01-环境准备.md)。

## 构建

```powershell
cd examples\ai8051u_blink
.\build.ps1
```

脚本内部三步：

1. `sdcc -mmcs51 --model-large -c` 编译 `main.c`、`AI8051U_Delay.c` 为 `.rel`；
2. `zig build-obj -target mcs51-freestanding` + `sdas8051` 把 `led.zig` 编成 `.rel`；
3. `sdcc -mmcs51 --model-large <所有 .rel> -o blink.ihx` 链接（自动带上 SDCC
   启动代码与运行库）。

## 烧录

1. 用 STC-ISP（AI8051U 版）选择型号，装入 `blink.ihx`，下载；
2. 目标主频设为 **40MHz**，与 `lib/stc-hal/config.h` 的 `MAIN_Fosc` 一致，
   否则 `delay_ms()` 延时不准。

## 工作原理

### C 侧（`main.c`）

```c
#include "config.h"            /* 主时钟、类型、ai8051u_sfr.h */
#include "AI8051U_GPIO.h"      /* P1_MODE_OUT_PP、GPIO_Pin_All */
#include "AI8051U_Delay.h"     /* delay_ms */

extern u8 led_next(u8 cur);    /* Zig 提供 */

void main(void)
{
    u8 led = 0x01;
    P1_MODE_OUT_PP(GPIO_Pin_All);   /* P1 全部推挽输出 */
    P1 = ~led;                       /* 低电平点亮 */
    while (1) {
        led = led_next(led);         /* Zig 算下一个灯位 */
        P1 = ~led;
        delay_ms(200);               /* STC HAL 延时 */
    }
}
```

### Zig 侧（`led.zig`）

```zig
export fn led_next(cur: u8) u8 {
    const had_high: bool = (cur & 0x80) != 0; // 即将移出的最高位
    var next: u8 = cur +% cur;                // 左移一位
    if (had_high) next |= 1;                  // 最高位回卷到最低位
    if (next == 0) next = 1;                  // 全灭时从 P1.0 重来
    return next;
}
```

### 接口与 ABI

接口刻意只用「单字节参数 + 单字节返回」，与 SDCC MCS-51 默认 ABI 完全一致
（参数在 `DPL`、返回在 `DPL`），Zig 后端生成的 `_led_next` 正好对接 SDCC 的
`mov dpl,#x; ljmp _led_next`。详见 [03-C与Zig混编与ABI.md](03-C与Zig混编与ABI.md)。

## 扩展

- **加更多灯效**：在 `led.zig` 里增加 `export fn` 并在 C 里调用即可，注意保持
  单字节/定长标量接口。
- **切换到 MCS-251**：把 `build.ps1` 里的 `-mmcs51`→`-mmcs251`、
  `mcs51-freestanding`→`mcs251-freestanding`、`sdas8051`→`sdas251`，并按
  [05-移植到MCS-251.md](05-移植到MCS-251.md) 准备 `sdcc-c251`。
- **换外设**：直接调用 `lib/stc-hal/` 下对应的 HAL（UART/PWM/Timer…）。
