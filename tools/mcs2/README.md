# mcs2 垂直切片（MIR → MCS51 汇编 → ucsim）

本目录是干净 0.17 树上的**第一块迁移地基**，不是完整后端。

## 当前范围

- 一个最小的 MIR 模型：立即数、8 位加法、写 xdata、停机；
- 一个 MCS51 汇编发射器：虚拟值全部落 DSEG，算术经 A；
- 一条可复现验证链：

```text
MIR(host Zig) → out.asm → sdas8051 → out.rel → sdld → out.ihx → ucsim_51
```

- 期望结果：程序把 `3 + 4` 写入 `xdata 0x8000`，ucsim dump 应为 `07`。

**没有做的事（下一阶段）：**

- 尚未接入 `src/codegen` 与 AIR；
- 尚无参数 ABI、调用、分支、循环、寄存器分配；
- 尚无 251 路径；
- 尚未处理中断、位空间、别名与 volatile。

## 运行

**只有一个入口** `mcs2.py`（工具发现 / 环境 / 布局 / 驱动桩 / ucsim 解析都在这里）：

```bash
cd zig-0.17/tools/mcs2
python mcs2.py build          # 同步源码 + 构建编译器（增量几秒 / 全量 2-3 分钟）
MCS2_RELEASE=1 python mcs2.py build   # ReleaseFast：不带 SafeAllocator 泄漏检查，日常用更干净更快
python mcs2.py check          # 全部仿真验收（133 项）
python feature_probe.py       # 定点能力矩阵（28 项支持 / 1 项拒绝）
python bench_compare.py       # mcs2 / SDCC / Keil 三方**函数体**尺寸（Keil 用 KEIL_BIN 或自动发现）
python fwsize.py              # 三方**总固件**尺寸（含被拉进来的库），Δ 相对空程序基线
python realcheck.py --sim     # 真机脚本分组 + ucsim 自检（26 组）
python realcheck.py --read <COMx>      # 逐组烧录后读串口逐项比对
python realcheck.py --dl <COMx>        # 发触发字节让固件软复位进 ISP（免按 RST）
python interop/build.py       # C(SDCC)↔Zig(mcs2) 混编实验（能链能跑，见 docs）
python mcs2.py check add sum  # 只跑点名用例
python mcs2.py fw uart --tag 45.1584M_9600   # 出固件 build/fw/uart_demo_8h8k64u_45.1584M_9600.ihx
python mcs2.py doctor         # 体检：工具/产物在哪、源码是否已同步
python mcs2.py clean          # 删编译器缓存（zig017/cache-mcs2*；下次全量构建）
python mcs2.py all            # build + check
```

固件产物统一写到**工作区 `build/fw/`**（与历史固件同处，烧录脚本按目录取）；
`--tag` 用来在文件名里记下时钟/波特率这一版是按什么算的。
环境变量 `ZIG017` 可覆盖编译器路径（默认构建树产物）。

旧脚本（`verify.py` / `add_check.py` / `loop_check.py` / `relax_check.py` /
`interrupt_check.py` / `make_uart_demo.py`）保留为薄封装，行为不变。

### 两棵树与硬链接

- `zig-0.17/src/codegen/mcs2*`：**源码真源**，所有编辑都在这里；
- `zig017/mcs2build`：**编译器构建树**，它的 `src/lib` 是打过 mcs51/mcs251
  （含 `McsInterruptOptions`）补丁的版本；
- `mcs2.py sync` 把源码**硬链接**进构建树（同一文件，改一处两处都变）；
  跨卷失败时自动退回复制。**不再需要手工 Copy-Item。**

依赖：系统 `zig`（构建编译器本身）、`sdas8051/sdld`（`MCS_SDCC_BIN` 可覆盖）、
`ucsim_51`（`UCSIM51` 可覆盖）。

## 调试产物

**SDCC 调试只留接口，暂不实现。** `src/codegen/mcs2/debug.zig` 定义
`SourceLoc`、`Symbol`、`DebugInfo` 与 `Sink`；`mcs51.emitWithDebug()` 已能接收 sink，
但当前没有 `.cdb` 编码器，也没有写任何调试文件。

- **MCS251-LLVM**：`mcs251-lld` 直接产 ELF；目前目标后端未输出 DWARF，
  ELF 里只有代码段与符号，不是源码级调试信息。
- **MCS51-ASM**：`sdas8051/sdld` 没有原生 ELF 输出；原生调试格式是
  `sdld -y` 生成的 `.cdb`，供 `sdcdb`/ucsim 使用。该编码器留作后续工作。
- 若外部工具需要 ELF，可另做“地址+符号”的调试容器，但 GDB 没有 MCS51 目标支持，
  不能据此获得源码级断点。

**结论：** 51 的 `.cdb` 接口已预留、实现暂缓；251 走 ELF，DWARF 后续补。

## 产物与构建入口

- `verify.py` 现在同时产出：
  - `build/out.ihx`：Intel HEX；
  - `build/out.hex`：规范化 HEX（`packihx`）。
- 汇编/链接/转换可单独复用：

```bash
python assemble51.py build/out.asm --out-dir build --name out
```

`assemble51.py` 是后续 `stage2_mcs2` 的 51 构建后端：
输入一份 ASxxxx 汇编，输出 `.rel`、`.ihx`、`.hex`。
**注意：** 当前 `CSEG=0x0000`、`DSEG=0x08` 是最小切片布局，
正式后端必须从设备表/链接脚本读取，不能沿用硬编码。

## 目标层探针

干净 0.17 已接入 `mcs51`/`mcs251` 目标与 `data/idata/xdata/code` 地址空间。
用仓库自带 `lib` 验证：

```bash
zig run --zig-lib-dir lib tools/mcs2/target_probe.zig
```

预期：

```text
mcs51  ptr bits = 24
mcs251 ptr bits = 24
addrspace.xdata = xdata
...
```

三 profile 的指针宽度、对象格式与工具链集中在
`src/codegen/mcs2/profiles.zig`，不要在后端或脚本里重复硬编码。

## 设计约束

1. **汇编器退出码必须检查**；失败不允许读到上一次的 `.rel/.ihx`。
2. **DSEG 基址固定为 0x08**；正式后端必须由链接布局决定，不能硬编码。
3. **MIR 不采用注释元数据**；当前只是最小结构体，后续扩展为带效果与放置的 schema。
4. **51 的 `add a,dir8` 合法**（2 字节），这里直接使用，不经 R7 中转。
5. **验证以 xram 读回为准**，不依赖串口时序。

## 下一刀

当前 MIR 与发射器已经落在：

```text
src/codegen/mcs2/mir.zig       数据结构与 profile
src/codegen/mcs2/mcs51.zig     MCS51 发射
src/codegen/mcs2/selftest.zig  验证入口
```

下一步是把 `selftest()` 替换为可序列化的 MIR schema，并接入 AIR；
在接入前不改动 `src/codegen` 的其他后端。
