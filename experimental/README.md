# 实验分支 `opt-tags`（更新说明）

> 本目录是 **`zig-mcs51-backend` 的实验分支 `opt-tags`** 的自包含构建与示例，
> **不进入 `mcs251` 分支**（`mcs251` 继续保持其发布/开发节奏）。实验性内容，随时可能改动。

## 相对 `mcs251-backend` 更新了什么

在原有 MCS-51/MCS-251 后端之上，新增「**数据放置标签 + GCC 对齐优化等级**」链路（仅后端 3 个文件）：

| 文件 | 更新 |
| --- | --- |
| `src/codegen/mcs/device.zig` | `Place` 五级（`data/idata/edata/xdata/exdata`）+ `Level`（`O0`–`O3`/`Ofast`/`Os`）+ `parseSection`/`levelName` |
| `src/link/Asx.zig` | 区名映射（`DSEG`/`ISEG`/`EDATA`/`XSEG`/`EXDATA`/`COLD`/`COLDX`）+ `areaFor`；每个函数/符号发 IR 提示 `; @tag func\|sym <name> <place><level>` |
| `src/codegen/mcs/CodeGen.zig` | `aggressiveSizeFor` 按等级选体积/速度；`edata`/`exdata` 放置 |

用法（Zig 源码里）：

```zig
const m = @import("mcs");
var hot: u8 linksection(m.data) = 0;                 // 放置到直接寻址 data
var big: [64]u8 linksection(m.xdata) = .{0} ** 64;   // 放到 xdata
fn fast() linksection(m.Ofast) void { ... }          // 速度优先
fn small() linksection(m.Os) void { ... }            // 体积优先
```

标签经 asm 注释传给中间层，由 `tools/mcs_ir.py` 消费并删除。

## 自包含构建（**不把 Python 冻成二进制**）

`build.ps1` 用**系统 zig** 从本树构建 MCS 编译器，再编译并链接示例；后处理工具
（`tools/*.py`）**直接用 Python 运行**，不生成 `mcstools.exe`。

```powershell
# 依赖：系统 zig 0.16.x 在 PATH；python 在 PATH；SDCC(mcs251) 提供 sdas251/sdcc
# <repo> 为本仓根
powershell -File experimental/build.ps1
# 产物：experimental/examples/ai8051u_zig_opt/opt.ihx
#   UART1 @9600 输出：opt 11223344 060a
```

常用参数：`-SkipCompiler`（复用已构建的编译器）、`-Loop`（启用 `MCS_LOOP` 循环优化）、
`-Sdcc <sdcc.exe>`、`-Device ai8051u-34k64`。

## 目录

| 路径 | 说明 |
| --- | --- |
| `build.ps1` | 自包含实验构建脚本（编译器 + 示例，Python 直跑） |
| `examples/ai8051u_zig_opt/` | **标签优化测试示例**（放置/等级，UART 输出 `opt 11223344 060a`） |
| `lib/mcs251.zig` | 共享 `@import("mcs")` 宏库（SFR/位/数据空间/标签常量） |
| `tools/*.py` | 构建层工具：`fix_mcs_labels`/`mcs_opt`/`mcs_ir`/`mcs_loop`/`mcs_device`/`mcs_cycles` 等 |
| `devices/` | 设备描述表（SFR/存储/中断），默认 `stc/ai8051u-34k64.toml` |
| `docs/` | 全部项目文档（`01`–`22`、PLAN、仓库说明等） |

## 说明

- 这是**实验分支**；正式开发/发布仍在 `mcs251`（开发源）与 `mcs8051`（发布仓）。
- 上游 Zig README 见 [`../README-zig.md`](../README-zig.md)。
