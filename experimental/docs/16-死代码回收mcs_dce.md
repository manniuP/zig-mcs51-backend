# 16 - 构建层死代码回收 `tools/mcs_dce.py`

> 目标：回收**未被引用**的函数/变量，省 Flash。
> 与 `tools/mcs_opt.py`（同地址空间内的指令级瘦身）互补——DCE 是**模块/符号级**的裁剪。

## 1. 背景与动机

- **Zig 源码级的未用函数/变量**：后端已自动剔除（懒分析）。实测：源里写个没人调用的
  `fn unused_fn()` / `var unused_var`，生成的 `.asm` 里**根本不出现**。
- **真正的浪费在链接层**：`sdld` **不回收未用段**，且 C（SDCC）与 Zig 的代码都进**单一
  `CSEG`**（无 per-function 段可删）。例：`cmd` 里 `_cobs_encode` / `_cobs_log_str` /
  `_mdu_div32s` / `_uart_puts` 等**根本没被调用**，却被整块链进镜像。
- 重编编译器也解决不了 **C 侧**，所以做成**构建层后处理**（和 `mcs_opt.py` 一个思路）。

## 2. 做法

对所有参与的 `.asm`（C 的 SDCC asm + Zig 的 asm）**一起**做跨模块可达性分析：

1. 按**顶格全局标签**（`^[A-Za-z_][A-Za-z0-9_]*:`）把每个文件切成「符号块」；局部标号
   （SDCC 的 `00130$` 等）不参与，随所在块保留。
2. 每个块的「引用」= 块内非注释文本里出现、且是**全工程定义的全局符号**的标识符。
   `.globl` **不算引用**（只是声明）。
3. **根** = `--keep` 文件里的全部定义 + 其文本里的全部引用（+ 额外 `--root`）。
   —— 入口模块（含 `_main`、**中断向量表**、crt0）用 `--keep`，其 `ejmp _isr` 等引用
   自然把 ISR 及其依赖拉进可达集。
4. 从根 BFS；删除**非 keep 文件**里不可达的块（及其 `.globl`）。
5. 删除时**必须保留结构指令**（`.area/.org/.module/...`）——否则后续代码会落错段
   （这是本工具实现时踩过并修掉的坑）。

然后在这些 `.asm` 交给 `sdas` 之前就地改写；`dce_rel()` 会把**非 keep** 的 `.asm` 重新
汇编回 `.rel`（覆盖 SDCC 产出的 `.rel`）。

## 3. 用法

```powershell
# 就地改写非 --keep 的 .asm（--keep 可多次；根）
python tools\mcs_dce.py --keep main.asm cobs.asm cordic.asm mdu.asm uart251.asm
python tools\mcs_dce.py --stats --keep main.asm lib.asm    # 打印删除清单
python tools\mcs_dce.py --self-test                        # 内置回归
```

构建接入（`xmake/helpers.lua` 的 `dce_rel` + 目标里调用）：

```lua
local h = import("xmake.helpers", {rootdir = projdir})
h.dce_rel(projdir, path.join(path.directory(sdcc), "sdas251.exe"), get_config("python"),
          { {asm=cobs_asm, rel=cobs_rel}, ... },   -- 参与 DCE 并重汇编
          {main_asm})                              -- keep（入口：main/IVT/crt0）
```

## 4. 实测（`cmd`，2026-09-16）

- **CSEG：21160 → 18486 字节（-2674，≈-12.6%）**；回收 `_cobs_encode`、
  `_cobs_log_str/_bytes/_var`、`_mdu_div32s/_mod32s`、`_uart_puts`、`_uart_rx_push/_pop`
  及其 PARM/帧数据等。
- 验证：`mcs_dce --self-test` OK；QEMU smoke（`ping/led/echo/cordictest 130/0`）通过；
  真机（`mul/div` MDU 等）见 `docs/交接` §26。

## 5. 限制 / 注意

- **已初始化全局变量**：其初始化代码在 `GSINIT` 里、符号被 `GSINIT` 引用而保留，暂不回收
  （需连初始化代码一起去，属后续）。
- 只按**全局符号名**分块；跨模块的**函数指针表**靠文本引用识别（一般没问题）。
- `--keep` 必须给（否则会删光）；入口模块（main/IVT/crt0）务必 keep。
- 语义安全：只删「整块、按名字可证明无人引用」的东西；有疑问的（结构指令）一律保留。
