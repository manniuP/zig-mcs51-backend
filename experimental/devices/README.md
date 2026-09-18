# devices/ —— 设备描述（芯片契约）

本目录是「非经典 51 及衍生核」的**设备描述单一真源**。一份 TOML 描述一款（或一族）芯片的
厂商型号、各存储空间、复位/中断、外设寄存器与访问机制；工具链据此生成**链接参数/`.lk`**、
**crt0 向量表**、**SFR/HAL 头**，并让编译器知道常量/变量该放哪。

设计原则：**描述“机制/能力”，不描述“STC 寄存器名”**。这样 STC 之外的厂商（WCH/BYD 等）
只要新增一份 `families.toml` + 设备文件即可，不必改工具链代码。

> 现状：schema 与生成器（`tools/mcs_device.py`）已落地，STC 家族已建；AI8051U / STC8H
> 为完整样例，其余型号的存储布局已填、SFR/中断表待补厂商头。

## 1. 目录与用法

```
devices/
  README.md                 本文
  stc/
    器件矩阵.md             初步型号/存储矩阵 + 待核手册清单
    families.toml           家族注册表：内核档 + 外设互通组 + 各家族
    ai8051u-34k64.toml
    ai8h8k64u.toml
    stc8h8k64u.toml
    stc89c52rc.toml
    stc12c5a60s2.toml
    stc15w4k32s4.toml
    iap15f2k61s2.toml
    stc32g12k128.toml
```

```powershell
# 校验 + 摘要
python tools\mcs_device.py devices\stc\ai8051u-34k64.toml --emit summary
# 生成链接参数 / sdld 命令文件 / crt0 骨架
python tools\mcs_device.py devices\stc\stc8h8k64u.toml --emit sdcc-args
python tools\mcs_device.py devices\stc\stc8h8k64u.toml --emit lk
python tools\mcs_device.py devices\stc\ai8051u-34k64.toml --emit crt0
# 全部样例自测
python tools\mcs_device.py --self-test
```

## 2. STC 家族与外设互通（分类依据）

| 家族 | 内核档 | 外设互通组 | 说明 |
|---|---|---|---|
| STC89 / STC90 | `classic8051`（12T） | `classic` | 最经典 51 |
| STC12 | `fast8051`（1T） | `stc12` | STC89 + 一些外设 |
| STC15 / IAP15 | `fast8051` | `stc15` | 与 STC12 同路线，再加外设 |
| STC16 | `mcs251` | `stc15` | STC15 外设 + 251 核 |
| STC8 / STC8051 | `fast8051` | `stc8` | 与 STC32 外设互通 |
| STC32 | `mcs251` | `stc8` | 与 STC8 外设互通，仅换内核 |
| AI8 | `fast8051` | `ai` | AI 外设组 |
| AI32 / AI8051 | `mcs251` | `ai` | 与 AI8 外设互通，仅换内核 |

要点：`stc8` 与 `ai` 两组外设**不互通**（STC8 ≠ AI8）；同组内换内核只需换编译器。
`stc12 → stc15 → stc16` 是同一条外设演进线。

## 3. 设备文件字段

### `[device]`
`id / vendor / family / model / package / doc / sfr_source`
`family` 指向 `families.toml` 的 `[families.<name>]`，继承 `core_profile`、`peripheral_group`。

### `[code]` 程序存储器
`base / size / addr_width`（16 或 24）/ `movc` / `reset_vector` / `wait_states`。
> 关键差异：经典 `0000H`，AI8051U `FF:0000H`；>64K（如 STC32G 128K）需 24 位且不能放在
> `FF:0000`（会越过 24 位边界）。

### `[[memory]]` 数据/外设空间（可多条）
| 字段 | 取值 | 含义 |
|---|---|---|
| `kind` | `data / idata / edata / xdata / xdata_external / xfr / eeprom` | 空间类别 |
| `base`, `size` | | 地址范围 |
| `addressing` | `direct / indirect_r0 / movx_dptr / movx_dpx / movc / bit` | 访问方式（编译器放置/寻址用） |
| `enable` | `"AUXR.EXTRAM"` 等 | 使能位；缺省即始终可用 |
| `alias_of` | 另一 `kind` | 物理别名（如 251 的 `edata` 与低 RAM 同址），校验时不算冲突 |
| `conflicts_with` | 另一 `kind` | 逻辑冲突（如 STC8H 的 `xfr` 与片外 RAM `0FA00-0FFFF` 重叠） |
| `mode` | XFR 专用（见下） | |

### XFR 三种机制（`xfr.mode`）
- `dpx_window`：独立 24 位窗口（AI8051U / STC32：`7E:0000`，`@DPX` 访问）。
- `movx_dptr_overlap`：16 位 `MOVX @DPTR` 窗口并与片外 RAM 重叠（STC8H：`0FA00-0FFFF`）。
- `indirect_unlock`：间接/解锁式 XSFR（预留，WCH 类）。
`enable` 一般是 `"P_SW2.EAXFR"`（上电置 1）。

### `[stack]` / `[dptr]` / `[registers]` / `[register_bits]`
- `stack.space` + `top`：栈所在空间与初值（251=`spx`，8051=`sp`）。
- `dptr.count` / `select` / `extended`：双 DPTR、选择位、扩展指针（DPXL）。
- `registers`：机制寄存器最小集（`SP/SPH/DPL/DPH/DPXL/AUXR/P_SW2/IAP_*/...`）。
- `register_bits`：`"P_SW2.EAXFR" = 7` 之类，供 HAL/生成器置位。
- 完整 SFR/XFR 表用 `sfr_source` 指向厂商 Keil/SDCC 头（`tools/keil2sdcc.py` 转换）。

### `[xfr]`（XFR 内的寄存器，按时钟树分组）
例如 AI8051U 的 `CLKSEL = 0x7EFE00`；STC8H 的 `CLKSEL = 0xFE00`。

### `[interrupts]`
`vector_base / slot_bytes / formula`（本项目 `num*8+3`）/ `max_number` / `priority_levels` /
`numbering`（`linear` 或 `linear_gt31`，后者如 STC8H 中断号 >31 需特殊处理）。

### `[link]`（可选，覆盖推导值）
`data_loc / idata_loc / xstack_loc`。例：mcs251 需 `data_loc = 0x30`（避开寄存器组与位区）。

## 4. 生成契约（emit）

| emit | 产物 | 对应的链接概念 |
|---|---|---|
| `sdcc-args` | `--code-loc/--code-size/--data-loc/--idata-loc/--iram-size/--xram-loc/--xram-size/--stack-loc` | SDCC/`sdld` 驱动参数 |
| `lk` | `-b HOME/DSEG/ISEG/XSEG/PSEG/BSEG` | ASxxxx 段基址（对齐 sdld `.lk`） |
| `crt0` | 复位入口 + 栈初值（+ 可选向量表） | 启动文件骨架 |
| `summary/validate` | 摘要 / 校验报告 | — |

映射依据见 `docs/19-设备描述与链接脚本规则.md`（规划中）与 SDCC `src/SDCCmain.c` 的
`WRITE_SEG_LOC`；AI8051U 实际产出对照 `examples/ai8051u_zig_mem/mem.lk`。

## 5. 与编译/HAL 的接口（后续）

- **编译器**：读同一份表（转成 JSON/Zig comptime）驱动「常量/变量按空间放置」与寻址选择。
- **链接**：由 `[code]/[[memory]]/[stack]` 生成 `.lk`，做越界/重叠/超 64K 检查。
- **HAL**：按 `peripheral_group` 复用驱动，按 `[registers]/[xfr]` 生成寄存器绑定；
  同组换内核不改代码。

## 5.1 SFR 配置（`tools/mcs_sfr.py`）

设备文件不内联整张寄存器表，而是引用厂商头：

```toml
[device]
sfr_source = "../../tools/vendor/stc/keil/c51/STC8H.H"  # 厂商 Keil 头
[registers]        # 机制寄存器子集（链接/HAL/编译器需要）
[register_bits]    # "P_SW2.EAXFR" = 7（位号；基址非 8 倍数者为掩码）
[xfr]              # XFR 内时钟等
```

**厂商头来源**：本机 Keil 安装目录 `...\Keil_v5\{C51,C251}\INC\STC\`，已批量复制到
`tools/vendor/stc/keil/{c51,c251}/`（C51=8051，C251=251），共 20+ 款（含 `AI8H.H`、`AI32G.H`、
`AI8051U.H`、`STC32G.H`、`STC16F.H` 等）。家族→头映射见 `devices/stc/headers.toml`；
`--expand` 会按型号前缀自动把正确的 `sfr_source` 写进每个生成的设备 TOML。

```powershell
# 解析统计 / 生成片段 / 生成 C 头 / 生成 Zig 地址模块
python tools\mcs_sfr.py --input tools\vendor\stc\AI8051U.keil.h --emit stat
python tools\mcs_sfr.py --input tools\vendor\stc\AI8051U.keil.h --emit toml   # 可并入设备 TOML
python tools\mcs_sfr.py --input tools\vendor\stc\stc8h_SDCC_C51.h --emit c
python tools\mcs_sfr.py --input tools\vendor\stc\AI8051U.keil.h --emit zig
# 一步校验：按设备 TOML 的 sfr_source 自动解析并对拍
python tools\mcs_sfr.py --device devices\stc\gen\stc8g1k08.toml
python tools\mcs_sfr.py --self-test
```

要点：Keil `sbit BASE^n` 当 `BASE%8≠0` 时**不可位寻址**，解析为**掩码**（`[sfr_masks]`），
HAL/代码用 `|= / &=~`；这与 `keil2sdcc.py` 的退化规则一致。

**现状**：176 个生成设备全部按各自（子）家族头通过 `--device` 校验。

## 5.2 构建接入（`xmake/devices.lua`）

设备描述是**链接布局/启动/SFR 的唯一真源**，构建不再硬编码 `--code-loc/--data-loc/--xram-loc`：

```powershell
xmake f --mcs_arch=mcs251 --device=devices\stc\ai8051u-34k64.toml
xmake build devhdr    # → build/devices/{device_sfr.h, device_sfr.zig, device.lk, crt0_device.asm}
xmake build devled    # 用设备表推导的链接参数构建 C 点灯（mcs251）
```

- `helpers.device_sdcc_args`：取 `mcs_device.py --emit sdcc-args`（`--code-loc/--code-size/--data-loc/
  --idata-loc/--iram-size/--xram-loc/--xram-size`）；`devled` 实测 `.lk` 出 `-b HOME=0xff0000`、
  `-b XSEG=0x10000`、`-C 0x10000 -X 0x8000 -I 0x0100`，与设备字段一致。
- `helpers.device_sfr_header/device_sfr_zig`：由 `mcs_sfr.py --emit c|zig` 生成。
- `helpers.device_emit`：`--emit lk|crt0` 生成 sdld 命令文件与启动骨架。

## 5.3 编译器接入（`MCS_DEVICE`）

MCS 后端读环境变量 **`MCS_DEVICE` = 内存模型 JSON 文本**（由 `mcs_device.py --emit compiler-json`
生成），据此**自动放置全局变量**并选择寻址空间。实现见 `compiler/src/codegen/mcs/device.zig`，
两处放置点共用同一 `device.decide`：`link/Asx.zig:updateNav`（分配 `.area`）与
`codegen/mcs/CodeGen.zig:resolvePtrIndex`（寻址空间）。

策略：
- 显式 `linksection`（`.data`/`.hot`→DSEG、`.idata`→ISEG）优先；`.cold`→独立 COLDX；
- 未标注：`size ≤ 2` 且设备有 data 空间 → **data**；否则 → 设备默认数据空间（本型号 xdata）。
- **未设 `MCS_DEVICE` 时行为不变**（默认 xdata），旧构建/示例零回归。

```powershell
# 示例：构建 devzig（纯 Zig，生成的 dev 模块 + 自动放置）
xmake f --mcs_arch=mcs251 --device=devices\stc\ai8051u-34k64.toml
xmake build devzig
```

新示例 `examples/ai8051u_dev/led.zig`：
```zig
const dev = @import("dev");   // 生成的 device_sfr.zig（SFR 地址）
const m   = @import("mcs");   // lib/mcs251.zig
const P1_ADDR: u8 = @intCast(dev.sfr.P1);
var ticks: u16 = 0;           // 2B → 自动 data（DSEG）
var buf: [16]u8 = undefined;  // 16B → 自动 xdata（XSEG）
```

## 6. TODO

- STC89/STC12/STC15/IAP15/STC32G 的 SFR 表与中断表：补厂商 Keil/SDCC 头并接 `keil2sdcc.py`。
- STC32G 复位入口/向量基址与 SRAM 划分：核 `STC32G-20260709.md` 第 11 章。
- STC89C52RC 附加 256B RAM 的基址；IAP15 片内 XRAM 精确尺寸。
- 新增 `--emit sfr-header`（由 `sfr_source` 交叉校验 `[registers]`）。
