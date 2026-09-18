# AI8051U 流水灯 demo（C + Zig）

一个最小的 **C + Zig 混合工程**：C 用 STC 官方 AI8051U HAL C 库驱动 P1，
Zig MCS 后端负责流水灯图案的计算，两者由 SDCC 工具链链接成同一个 Intel HEX。

> 源码在 `examples/ai8051u_blink/`，本说明文档统一收录在 `docs/`。

## 效果

- P1.0 ~ P1.7 接 8 个 LED（低电平点亮）；
- 上电后 P1.0 先亮，随后每 200ms 依次点亮下一位，到 P1.7 后回到 P1.0 循环。

## 文件

| 文件 | 说明 |
| --- | --- |
| `main.c` | C 主程序：用 STC HAL 把 P1 配成推挽输出、写 P1、调用 `delay_ms` |
| `led.zig` | Zig 逻辑：`export fn led_next(u8) u8`，返回下一个灯位（循环左移） |
| `build.ps1` | 构建脚本：C → `.rel`，Zig → `.asm` → `.rel`，再链接成 `.ihx` |

用到的 AI8051U C 库（`lib/stc-hal/`）：

- `AI8051U_GPIO.h`：`P1_MODE_OUT_PP`、`GPIO_Pin_All` 等端口模式宏；
- `AI8051U_Delay.c/.h`：`delay_ms()` 软件延时。

## 编译

```powershell
cd examples\ai8051u_blink
.\build.ps1
```

依赖：

- 本机 SDCC 4.5.20（含 `sdcc.exe`、`sdas8051.exe`），默认路径
  `C:\Program Files (x86)\SDCC\bin`；
- 预编译的 `compiler\zig-out\bin\zig.exe`（55MB，见 [01-环境准备](01-环境准备.md) 第 3 节）。

产物：`blink.asm`/`led.asm`、`*.rel`、`blink.ihx`、`blink.map`。

## 烧录

1. 用 **STC-ISP**（AI8051U 版）选择目标型号，装订 `blink.ihx`，下载；
2. 目标主频按 `config.h` 的 `MAIN_Fosc = 40000000L`（40MHz）设置，
   否则 `delay_ms()` 的延时不准。

## 为什么用 `-mmcs51`

本机安装的 SDCC 只带 `sdas8051`，没有支持 MCS-251 的 `sdas251`/`sdld`。
AI8051U 兼容经典 8051 指令，因此 C 走 `sdcc -mmcs51`，Zig 走
`-target mcs51-freestanding`。若要真正使用 AI8051U 的 MCS-251 核，需先按
[08-驱动与链接详解](08-驱动与链接详解.md) 编译 `sdcc-c251` 得到 `sdas251`/`sdld`，
再把 `build.ps1` 里的目标换成 mcs251。

## C / Zig 的接口约定

接口刻意只使用「单字节参数 + 单字节返回」，正好命中 SDCC MCS-51 默认 ABI：

- 参数放在 `DPL`；
- 返回值放在 `DPL`。

Zig 后端对 MCS-51 生成的 `_led_next` 同样从 `DPL` 取参、写回 `DPL`，因此
C 的 `mov dpl,#x; ljmp _led_next` 与 Zig 的实现可直接对接，无需额外约定。
