# 14 STC Keil 库移植到 SDCC（以 USB-CDC 为例）

> 目标：STC 只给了 Keil C251 的 `.LIB`（USB 等），要让它在本仓库的 **SDCC mcs251** 工具链里能用。
> 以「Ai8051U-32Bit/43 USB-CDC」为例走通了整条路，并踩平两个 **SDCC 专属坑**。
> 工程见 [`../examples/ai8051u_usb_cdc/`](../examples/ai8051u_usb_cdc/README.md)。

## 1. 总体步骤

1. 从官方 `AI8051U-DEMO-CODE-V1.2.zip` 抽 `Ai8051U-32Bit/43-USB-CDC/{src,obj}` 与 `Ai8051U-32Bit/COMM/`。
2. 用 [`tools/keil2sdcc_c.py`](../tools/keil2sdcc_c.py) 把 Keil C251 源码翻成 SDCC：
   - `bit/xdata/code/interrupt N/sfr/sbit` → SDCC 关键字；
   - `#include "../comm/AI8051U.h"` → `ai8051u_sfr.h`、`<intrins.h>` → `mcs_intrins.h`；
   - 非可位寻址 SFR 位改写为字节操作。
   （已增强脚本以兼容 `../comm/AI8051U.H` 尖括号/相对路径写法。）
3. 用 `sdcc -mmcs251 --model-large` 编译、`--code-loc 0xff0000` 链接。
4. 可用 `sdar`/`sdranlib` 打成 SDCC `.lib`（对应 STC 的 Keil `.LIB`）。

## 2. 坑一：SDCC 的中断向量表只在「含 main 的模块」生成

`SDCCglue.c:createInterruptVect()` 仅在**定义了 `main` 的模块**里生成 IVT，且只收**本模块**的
`__interrupt` 函数。若 ISR 与 `main` 分处不同 `.c`（分开编译），IVT 里就不会有这些向量，
中断永不触发（但代码本身照常链接、`_xxx_isr` 符号也在）。

**解法**：用**单编译单元**把 `main` 与全部 ISR 放进同一次编译：

```c
/* usb_cdc_all.c */
#include "main.c"
#include "uart.c"
#include "usb.c"       /* 里面 usb_isr() __interrupt(25) */
/* … */
```

生成后可在 `.ihx` 里核对：向量槽 = `0x0003 + N*8`（mcs251 每槽 8 字节：`ejmp 4 + .ds 4`）。
例：`vector 8 @0xFF0043 → ejmp _uart2_isr`、`vector 25 @0xFF00CB → ejmp _usb_isr`。

> 注意：加了单编译单元后，**不要**再单独编译那些 `.c`（符号会重复）。

## 3. 坑二：ISR 与主循环共享的变量必须 `volatile`

SDCC 会缓存/优化普通全局，主循环读不到 ISR 更新的值（Keil 对此不敏感）。症状很典型：

- **USB 能枚举**（EP0 控制走 ISR 正常，设备名/描述符都对）；
- 但 **EP1 块数据不通**（回环无回显）——因为 `uart_polling` 读不到 `RxRptr/RxWptr`、
  `UsbInBusy` 等被 ISR 改动的值。

**解法**：给这些变量加 `volatile`（声明与 `extern` 都要）：

```
DeviceState, InEpState, OutEpState, UsbInBusy, UsbOutBusy,
RxRptr, RxWptr, TxRptr, TxWptr, RxBuffer, TxBuffer, (uart.c) UartBusy
```

## 4. 其他适配

- **内存模型**：Keil 例程常用 XSmall（局部默认 edata）；SDCC 用 `--model-large`（全局进 xdata）。
- **时钟/波特率**：`uart.h` 的 `BR(n)` 依赖 `config.h` 的 `FOSC`，要按实际 IRC 改（本板 40MHz）。
- **引脚复用**：UART2 选 P4.2/P4.3（`P_SW2 |= 0x01`）；回环时把 TXD2 设推挽更干净。
- **USB 时钟**：`usb_init` 里 `IRC48MCR=0x80` 启动内部 IRC48M，USB 走它，与系统 FOSC 无关。

## 5. 验证（AI8051U-34K64）

- 设备枚举：`VID_34BF&PID_FF02`，`BusReportedDeviceDesc="AIC USB Serial"`，COM10=`USBSER000`。
- UART2 桥接回环：P4.2↔P4.3 跳线，PC 经 COM10 发 `LOOP0..LOOP4` → **原样回显**。
- 对照：STC 官方 Keil `usb_ser.hex` 同板同跳线也回环 → 硬件/接线无误，差异全在 SDCC 移植。

## 6. 对后续库移植的清单

1. 抽源码 → `keil2sdcc_c.py` 翻译；
2. **单编译单元**（main + 全部 ISR）；
3. **ISR 共享变量加 `volatile`**；
4. 按需改 `FOSC`、引脚复用、推挽；
5. `--code-loc 0xff0000` 链接；
6. 真机验证（有可观察输出再上板；无按键时改成周期性输出，见 USB-HID）。

## 7. 已按此移植并真机验证的库

- **USB-CDC**：[`../examples/ai8051u_usb_cdc/`](../examples/ai8051u_usb_cdc/README.md)，
  P4.2↔P4.3 跳线回环通过。
- **USB-HID**：[`../examples/ai8051u_usb_hid/`](../examples/ai8051u_usb_hid/README.md)，
  本板无按键 → 改为**持续上报**，主机 `hidread.ps1` 读到递变的 64 字节报告。

其他只有 Keil `.LIB`、无源码的（MDU32/TFPU/FPMU）不能用此法；DSP32 有 `.ASM` 源可另行翻译。
