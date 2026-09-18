# 文档总目录（MCS-51 / MCS-251 / STC AI8051U）

本目录是**仓库全部文档的唯一位置**（原根目录的 PLAN / README，以及 `driver/`、
`examples/`（旧）等处的 README 都已并入这里，见文末“文档搬迁对照”）。仓库根只留一个入口
`README.md` 指向本页。

> 仓库已按「**编译器 / 库 / 示例 / 文档 / 工具**」重组顶层目录：
> `compiler/`（原 `zig/`，Zig + MCS 后端源码）、`lib/`（原 `port/` + `include/`，
> 含 `cobs/`、`uart251/`、`stc-hal/`、`include/`、`crt0/`）、`examples/`（原 `projects/`、
> `examples/`）、`docs/`、`tools/`（脚本 + 预编译 SDCC + vendor）。详见
> [02-工程结构与构建流程](02-工程结构与构建流程.md)。

## 一、入门与流程（按序阅读）

1. [01-环境准备](01-环境准备.md) —— 工具链、路径、验证环境。
2. [02-工程结构与构建流程](02-工程结构与构建流程.md) —— 仓库布局与 Zig/C/链接三段式流程。
3. [03-C与Zig混编与ABI](03-C与Zig混编与ABI.md) —— 双方如何互相调用、ABI 约定、硬件操作放哪边。
4. [04-驱动脚本用法](04-驱动脚本用法.md) —— 构建驱动（现用 `xmake.lua`；旧 `driver/build.ps1` 已移除）。
5. [05-移植到MCS-251](05-移植到MCS-251.md) —— 从 8051 兼容模式切到 251 核。
6. [06-常见问题与限制](06-常见问题与限制.md) —— 报错排查、后端限制、编码坑。
7. [07-调试笔记-ptr_rt自举崩溃定位](07-调试笔记-ptr_rt自举崩溃定位.md) ——
   自举崩溃定位、磁盘清理、“不再自举、固定预编译编译器”，以及 **ptr_rt 跑通** 的完整记录。

## 二、驱动、工程与示例

- [08-驱动与链接详解](08-驱动与链接详解.md) —— SDCC 编译/链接命令、`.lk` 结构、内存模型（原 `driver/README.md`）。
- [09-工程与示例总览](09-工程与示例总览.md) —— `examples/` 索引与新建工程约定（原 `projects/README.md`）。
- [10-工程-ai8051u_blink](10-工程-ai8051u_blink.md) —— 完整 C + Zig 流水灯工程说明。
- [11-示例-ai8051u_blink](11-示例-ai8051u_blink.md) —— 最小 C + Zig 示例说明（该示例已并入
  `examples/ai8051u_blink`）。
- [13-8位与32位模式与Flash布局](13-8位与32位模式与Flash布局.md) —— AI8051U 单核双模、
  共用同一 64K Flash/复位入口，两种固件不能并存（含 8 位固件构建方法）。
- [14-USB-CDC移植笔记](14-USB-CDC移植笔记.md) —— 把 STC 的 Keil C251 库（USB）移植到 SDCC
  mcs251 的完整方法，含两个 SDCC 专属坑（IVT 只在 main 模块、ISR 共享变量需 volatile）。
- [15-汇编瘦身工具mcs_opt](15-汇编瘦身工具mcs_opt.md) —— 构建层后处理 `tools/mcs_opt.py`
  （R1~R5：合并 spx 调整、删冗余 mov、常量转发、无用代码/跳转回收），无需重编编译器；
  含各例程 CSEG 实测（mcs251 普遍 -12~-18%，`zigmem` -40%；mcs51 很小）。
- [16-死代码回收mcs_dce](16-死代码回收mcs_dce.md) —— 构建层 `tools/mcs_dce.py`：跨模块可达性
  分析，删除**未被引用**的函数/变量（`sdld` 不回收未用段、C/Zig 同挤一个 CSEG）；`cmd` 实测
  CSEG 21160→18486（-12.6%）。
- [17-后端IR提示与中间层优化](17-后端IR提示与中间层优化.md) —— 后端在 asm 里夹带类 IR 提示
  （`; vN …`），中间层 `tools/mcs_ir.py` 做值级**死 store 消除**；先在
  `examples/vscode_mixed_xmake_zig/` 接入。
- [18-后端尺寸与mcs51多字节端序](18-后端尺寸与mcs51多字节端序.md) —— `appendAdjust` 单条
  `add/sub spx,#imm16`、`-OReleaseSmall` 条件融合扩展（`.not`/`.bool_and`/`.bool_or`）、
  **MCS-51 多字节内存读端序修复**（`memByteDisp`）、延伸的 mcs51 自检。
- [21-指令周期参考与bench验证](21-指令周期参考与bench验证.md) —— AI8051U 附录A.1.3 指令周期
  参考表 + `tools/mcs_cycles.py`（逐条/按函数静态周期）+ 真机 `zigbench` 逐周期验证 + 优化收益计算。
- [22-循环下行计数DJNZ](22-循环下行计数DJNZ.md) —— 构建层 `tools/mcs_loop.py`：把后端生成的
  计数 `while` 循环改写为「下行计数 + `djnz`」（`MCS_LOOP=1`），真机 `zigbench` 读循环 −63%~−70%。

源码位置：`../examples/ai8051u_blink/`、`../examples/ai8051u_ptrtest/`
（3 字节指针互操作见 [07](07-调试笔记-ptr_rt自举崩溃定位.md)）。

## 三、计划与仓库说明

- [PLAN-计划](PLAN-计划.md) —— 总体计划、ABI 冻结、里程碑（原根 `PLAN.md`）。
- [PLAN-计划-中英](PLAN-计划-中英.md) —— 中英对照版（原根 `PLAN_zh_en.md`）。
- [仓库说明-中文](仓库说明-中文.md) —— 仓库结构、构建、状态（原根 `readme_zh.md`）。
- [仓库说明-English](仓库说明-English.md) —— English overview（原根 `README.md`）。

## 四、运维

- [12-可清理与重新下载清单](12-可清理与重新下载清单.md) —— 已清理的大件（Keil 安装、
  sdcc-c251 源码、缓存）及日后恢复方法；同时列出“不要删”的必需件。
- 给 AI 助手的协作约定（工作区级）：[`../../docs/AI-协作约定.md`](../../docs/AI-协作约定.md)
  （工作区根另有 `AGENTS.md` 入口）。

## 定位（一句话）

- **Zig**：由 MCS 后端 `compiler/src/codegen/mcs/` 直接产出 ASxxxx 汇编（`.asm`），
  用 `../compiler/zig-out/bin/zig.exe`（唯一可用的预编译编译器）编译。
- **C**：由 SDCC（`-mmcs51` / `-mmcs251`）产出 `.rel`。
- **链接**：两者都是 SDCC ASxxxx 目标，用 `sdas` + `sdld`（或 `sdcc` 驱动）链成同一个 Intel HEX。

> **可自举**：用系统 zig（0.16.0）从 `compiler/` 源码重建编译器（`compiler/zig-out/bin/zig.exe`），
> 不再依赖旧的 55MB bootstrap（已删除）。管线仍是「zig 编译 Zig 源 + sdcc 编译 C + 链接」。

## 文档搬迁对照

| 原位置 | 现位置 |
| --- | --- |
| `driver/README.md` | [08-驱动与链接详解](08-驱动与链接详解.md) |
| `examples/README.md` | [09-工程与示例总览](09-工程与示例总览.md) |
| `examples/ai8051u_blink/README.md` | [10-工程-ai8051u_blink](10-工程-ai8051u_blink.md) |
| `examples/ai8051u_blink/README.md` | [11-示例-ai8051u_blink](11-示例-ai8051u_blink.md) |
| 根 `PLAN.md` | [PLAN-计划](PLAN-计划.md) |
| 根 `PLAN_zh_en.md` | [PLAN-计划-中英](PLAN-计划-中英.md) |
| 根 `readme_zh.md` | [仓库说明-中文](仓库说明-中文.md) |
| 根 `README.md` | [仓库说明-English](仓库说明-English.md)（根 `README.md` 改为入口） |
