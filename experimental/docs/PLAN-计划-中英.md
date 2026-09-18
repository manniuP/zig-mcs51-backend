# 计划（PLAN）

> 本文档为中英文逐段对照版：每段中文下方紧跟对应的英文原文。
> （G/H/I 三节原文即为中文，故仅保留中文并注明。）

目标：为 MCS-51 / MCS-251 编译 Zig + C，由 SDCC 的 `sdld` 链接成单个镜像。

Goal: compile Zig + C for MCS-51 / MCS-251, linked into one image by SDCC `sdld`.

分工：

Division of labor:

- Zig：自托管后端 `src/codegen/mcs/`，输出 ASxxxx 汇编文本，复用 `sdas251`/`sdas8051`。
- Zig: self-hosted backend `src/codegen/mcs/`, emits ASxxxx assembly text, reuses `sdas251`/`sdas8051`.
- C：`sdcc -mmcs51` / `sdcc -mmcs251`，输出 ASxxxx `.rel`。
- C: `sdcc -mmcs51` / `sdcc -mmcs251`, emits ASxxxx `.rel`.
- 链接：`sdld` + SDCC 运行时 + 启动代码/中断向量。
- Link: `sdld` + SDCC runtime + startup/ISR vectors.
- C++：暂不在范围内（SDCC 没有 C++ 前端）。
- C++: out of scope for now (SDCC has no C++ frontend).

参考行号为近似值，会随上游改动而偏移。

Reference line numbers are approximate and shift with upstream edits.

## A. 目标描述层（lib/std）

## A. Target description layer (lib/std)

1. `compiler/lib/std/Target.zig`

   - `Arch` 枚举（~1352）：添加 `mcs51`、`mcs251`。
   - `Arch` enum (~1352): add `mcs51`, `mcs251`.
   - `Arch.Family`（~1417）：添加 `mcs51`、`mcs251` 族（每个都需要一个 `std.Target.<tag>` 命名空间）。
   - `Arch.Family` (~1417): add `mcs51`, `mcs251` families (each needs a `std.Target.<tag>` namespace).
   - `Arch.endian()`（~1662）：`mcs51 -> .little`，`mcs251 -> .big`。
   - `Arch.endian()` (~1662): `mcs51 -> .little`, `mcs251 -> .big`.
   - `Arch.fromCallingConvention()`（~1784）：映射新的调用约定。
   - `Arch.fromCallingConvention()` (~1784): map new calling conventions.
   - `toElfMachine()`（~1120）/ `toCoffMachine()`（~1148）：加入 `.NONE` / `.UNKNOWN` 组。
   - `toElfMachine()` (~1120) / `toCoffMachine()` (~1148): add to `.NONE` / `.UNKNOWN` groups.
   - `ptrBitWidth_arch_abi()`（~2904）：`mcs251 -> 24`，`mcs51 -> 16`。
   - `ptrBitWidth_arch_abi()` (~2904): `mcs251 -> 24`, `mcs51 -> 16`.
   - `cCallingConvention()`（~3769）：SDCC C ABI（`--stack-auto` 形式）。
   - `cCallingConvention()` (~3769): SDCC C ABI (`--stack-auto` form).
   - `min/defaultFunctionAlignment()`（~828/~799）：字节对齐。
   - `min/defaultFunctionAlignment()` (~828/~799): byte alignment.
   - `ObjectFormat.default()`（~1069）：默认 `.hex`。
   - `ObjectFormat.default()` (~1069): default `.hex`.

2. `compiler/lib/std/Target/mcs51.zig`、`mcs251.zig`（新建）：`Feature`、`featureSet*`、`all_features`、`cpu` 模型。在 `Target.zig` 中添加 `pub const mcs51 = @import("Target/mcs51.zig");` 等（~767 区域）。

   `compiler/lib/std/Target/mcs51.zig`, `mcs251.zig` (new): `Feature`, `featureSet*`, `all_features`, `cpu` models. Add `pub const mcs51 = @import("Target/mcs51.zig");` etc. in `Target.zig` (~767 region).

3. `compiler/lib/std/lang.zig`

   - `AddressSpace`（~528）：添加 `data/idata/pdata/xdata/code/sfr/sbit`；将 `enum(u5)` 改为 `enum(u6)`。
   - `AddressSpace` (~528): add `data/idata/pdata/xdata/code/sfr/sbit`; change `enum(u5) -> enum(u6)`.
   - `CallingConvention`（~125）：添加 `mcs51_sdcc`、`mcs251_sdcc` 及中断变体。
   - `CallingConvention` (~125): add `mcs51_sdcc`, `mcs251_sdcc` + interrupt variants.
   - `CompilerBackend`（~1230）：添加 `stage2_mcs`。
   - `CompilerBackend` (~1230): add `stage2_mcs`.

## B. 编译器核心（src）

## B. Compiler core (src)

4. `zig/src/target.zig`

   - `zigBackend()`（~978）：将 `mcs51`/`mcs251` 映射到 `.stage2_mcs`。
   - `zigBackend()` (~978): map `mcs51`/`mcs251` to `.stage2_mcs`.
   - `hasLlvmSupport()`（~200）：返回 `false`。
   - `hasLlvmSupport()` (~200): return `false`.
   - `defaultAddressSpace()`（~618）：全局变量 -> `xdata`，常量/函数 -> `code`。
   - `defaultAddressSpace()` (~618): globals -> `xdata`, constants/functions -> `code`.
   - `addrSpaceCastIsValid()`（~644）及相关谓词：添加分支。
   - `addrSpaceCastIsValid()` (~644) and related predicates: add cases.

5. `zig/src/codegen.zig`

   - `devFeatureForBackend`（~29）、`importBackend`（~47）、`legalizeFeatures`（~64）、`generateFunction`（~148）、`emitFunction`（~189）、`generateLazyFunction`（~221）：添加 `.stage2_mcs`。
   - `devFeatureForBackend` (~29), `importBackend` (~47), `legalizeFeatures` (~64), `generateFunction` (~148), `emitFunction` (~189), `generateLazyFunction` (~221): add `.stage2_mcs`.
   - `AnyMir` 联合（~100）：添加 `mcs` 变体 + `tag()`。
   - `AnyMir` union (~100): add `mcs` variant + `tag()`.

6. `compiler/src/codegen/mcs/`（新建，参照 `codegen/riscv64/`）

   `compiler/src/codegen/mcs/` (new, model after `codegen/riscv64/`)

   - `CodeGen.zig`：`legalizeFeatures`、`generate`、`generateLazy`。
   - `CodeGen.zig`: `legalizeFeatures`, `generate`, `generateLazy`.
   - `Mir.zig`：`deinit`、`emit`（输出 ASxxxx 汇编文本）。
   - `Mir.zig`: `deinit`, `emit` (writes ASxxxx assembly text).
   - `abi.zig`：SDCC ABI 第 2 版分类。
   - `abi.zig`: SDCC ABI rev 2 classification.
   - `encode.zig`/`Lower.zig`/`Emit.zig`：MCS-251 指令编码与降级。
   - `encode.zig`/`Lower.zig`/`Emit.zig`: MCS-251 encodings and lowering.

7. `zig/src/dev.zig`：添加后端特性（`mcs_backend`）和链接器特性（`asx_linker`/`hex_linker`）；更新特性组列表。

   `zig/src/dev.zig`: add backend feature (`mcs_backend`) and linker feature (`asx_linker`/`hex_linker`); update the feature group lists.

8. `zig/src/link.zig`

   - `File.Tag`（~1282）：为 ASxxxx/hex 路径添加一个标签。
   - `File.Tag` (~1282): add a tag for the ASxxxx/hex path.
   - `fromObjectFormat`（~1307）：`.hex` 目前会 panic（~1316）；需实现或映射。
   - `fromObjectFormat` (~1307): `.hex` currently panics (~1316); implement or map.
   - `zig/src/link/Asx.zig`（新建）：`open/createEmpty/updateFunc/updateNav/flush`。
   - `zig/src/link/Asx.zig` (new): `open/createEmpty/updateFunc/updateNav/flush`.

9. `zig/src/Compilation.zig` / `Config.zig`：后端选择；添加外部 SDCC 的 C 路径（目前只有内置 clang；见 `Compilation.zig` 中 `clangMain` ~33）。

   `zig/src/Compilation.zig` / `Config.zig`: backend selection; add the external-SDCC C path (only built-in clang exists today; `clangMain` in `Compilation.zig` ~33).

10. `compiler/lib/compiler_rt/`：不要从零重新实现软浮点/64 位除法；发出对匹配 ABI 的 SDCC 运行时符号的调用，或链接 SDCC `mcs251-*` 库。

    `compiler/lib/compiler_rt/`: do not reimplement soft-float/64-bit division from scratch; emit calls to SDCC runtime symbols with matching ABI, or link SDCC `mcs251-*` libraries.

11. SFR/位访问：C 使用 SDCC 头文件；Zig 使用固定地址 volatile，或后续添加 `@sfr`/`@bit` 内建函数（需改动 AstGen/Sema）。

    SFR/bit access: C uses SDCC headers; Zig uses fixed-address volatiles, or add `@sfr`/`@bit` builtins later (AstGen/Sema change).

## C. 构建与链接编排

## C. Build and link orchestration

12. 驱动（见 `driver/`）：`Zig -> asm -> sdas251 -> .rel`；`C -> .rel` 经由 SDCC；`sdld + libs + crt0 + vectors`。Zig 的构建系统目前还不调用外部 C 编译器。

    Driver (see `driver/`): `Zig -> asm -> sdas251 -> .rel`; `C -> .rel` via SDCC; `sdld + libs + crt0 + vectors`. Zig's build system does not invoke external C compilers yet.

13. 先做一致性测试（双向 ABI）：Zig 调 C、C 调 Zig、结构体/3 字节指针、中断、64 KiB 以上地址。参照 `abi.md` 的"Required conformance tests"。

    Conformance tests first (bidirectional ABI): Zig calls C, C calls Zig, structs/3-byte pointers, interrupts, addresses above 64 KiB. Mirror `abi.md` "Required conformance tests".

## D. ABI 冻结（采用现有方案，不自创）

## D. ABI freeze (adopt, do not invent)

- `-mmcs251`，ABI 第 2 版，大端标量，`size_t` = 32 位 `unsigned long`。
- `-mmcs251`, ABI revision 2, big-endian scalars, `size_t` = 32-bit `unsigned long`.
- 指针：near 1 字节，xdata/far/code/generic 3 字节（高字节在前）。
- Pointers: near 1 byte, xdata/far/code/generic 3 bytes (high byte first).
- 第一个标量参数/返回值放在 DPL/DPH/B/A；3 字节指针为 B:DPH:DPL；大返回值通过隐藏指针。
- First scalar arg/return in DPL/DPH/B/A; 3-byte pointer B:DPH:DPL; large returns via hidden pointer.
- 互操作采用重入栈约定；所有单元使用相同的选择。
- Reentrant stack convention for interop; all units use the same choice.
- 运行库：`mcs251-small-stack-auto`、`mcs251-large-stack-auto`，以及默认模型库。
- Runtime libs: `mcs251-small-stack-auto`, `mcs251-large-stack-auto`, plus default model libs.

## E. 里程碑

## E. Milestones

1. ABI 冻结文档 + 一致性测试框架（无代码生成）。
   ABI freeze docs + conformance test harness (no codegen).
2. Zig 后端为叶子函数输出 ASxxxx；用 SDCC 启动代码链接一个 Zig `main`。
   Zig backend emits ASxxxx for leaf functions; link a Zig `main` with SDCC startup.
3. Zig <-> C 双向调用，标量与 3 字节指针。
   Zig <-> C calls both directions, scalars and 3-byte pointers.
4. 地址空间（`xdata`/`code`/`sfr`/`bit`）与中断。
   Address spaces (`xdata`/`code`/`sfr`/`bit`) and interrupts.
5. 运行时集成（除法/浮点/mem）与完整启动。
   Runtime integration (division/float/mem) and full startup.
6. 可选：C++ 子集，或放弃。
   Optional: C++ subset, or drop.

## F. Keil 文档

## F. Keil documentation

核心计划不需要。仅在与 Keil 生态系统兼容时需要（Keil ABI、`using` 寄存器组、A51/A251 汇编、链接 Keil 库）。SDCC 移植明确不声称支持 Keil OMF-251 互操作。

Not required for the core plan. Needed only for Keil ecosystem compatibility (Keil ABI, `using` register banks, A51/A251 assembly, linking Keil libraries). The SDCC port explicitly does not claim Keil OMF-251 interoperability.

已足够：

Already sufficient:

- 指令集：STC `AI8051U-*.md` 附录 A（MCS-251 操作码、BINARY/SOURCE 模式）。
- Instruction set: STC `AI8051U-*.md` appendix A (MCS-251 opcodes, BINARY/SOURCE modes).
- 互操作 ABI：`sdcc-c251/doc/mcs251/abi.md`。
- Interop ABI: `sdcc-c251/doc/mcs251/abi.md`.
- 工具链内部：`sdcc-c251/src/mcs251/`、`sdcc-c251/sdas/as251`、`sdcc-c251/sdas/as8051`。
- Toolchain internals: `sdcc-c251/src/mcs251/`, `sdcc-c251/sdas/as251`, `sdcc-c251/sdas/as8051`.

## G. STC 官方资料（已归档到 tools/vendor/stc）

> 本节原文即为中文，无英文对照。

分类（来源：STC 官网下载，见 `tools/vendor/stc/`）：

可用：

- `AI8051U.keil.h`：STC 官方 Keil 头，116 `sfr` + 309 `sbit` + 670 条 `far` 指针 XFR
  定义，是 AI8051U 寄存器表的权威来源。经 `tools/keil2sdcc.py` 翻译为 `lib/include/ai8051u_sfr.h`。
- `stc8h_Compiler.h`：STC 的编译器抽象层，给出 SDCC 关键字映射
  （`SFR`/`SBIT`/`SFRX`/`INTERRUPT`/`INTERRUPT_USING`）。作为 `c51.h` 的权威参照。
- `stc8h_SDCC_C51.h`：STC 官方 SDCC SFR 头（STC8H），示范 XFR 用 `__xdata` 指针。
- `SDCC-Makefile.txt`：STC 的 SDCC 构建脚本，命令行为
  `sdcc -mmcs51 --model-large --code-size --iram-size --xram-size --out-fmt-ihx`，
  汇编器 `sdas8051`，链接由 `sdcc` 驱动。
- `USB_CDC_SDCC.lib` / `USB_HID_SDCC.lib`：SDCC ar/`rel` 库（`!<arch>`），
  但目标为 STC8H（mcs51）；AI8051U（mcs251）无对应 SDCC 库。
- `STC32_DSP32.ASM`：Keil A251 汇编，符号为 Keil ABI（`?C?ULDIV`），仅作参考，需改写。
- `hal/`：AI8051U 外设 HAL 源码（61 个 `.c/.h`，Keil 语法：`interrupt`/`using`/`xdata`/`bit`），
  移植到 SDCC/Zig 时需做关键字替换，逻辑可直接用。

用不了（二进制 / 工程 / 工具）：

- Keil 库：magic `2C 07`(C51) / `AC 07`(C251)，如 `AI8051U_8/32_*.LIB`、`STC32_MDU32_*.LIB`、
  `STC32_DSP32_*.LIB`、`stc_usb_*_32g*/8h*`。
- IAR 库：`USB_*_IAR.lib`（UBROF，magic `00 0B`）。
- Keil/IAR 工程与产物：`.uvproj/.uvopt`、`.ewp/.ewd`、`.aic`、`Auto_Keil.exe`、`.hex/.obj/.rel/.m51`。

结论：AI8051U 的寄存器描述（SFR/XFR/位/向量）可从 Keil 头自动翻译，已生成；
C 运行库（USB、MDU/DSP32）STC 只提供 Keil/IAR 二进制，SDCC 需自建或移植。

## H. 已生成/新增

> 本节原文即为中文，无英文对照。

- `include/c51.h`：SDCC 语法简化宏（内存段、SFR/SBIT、ISR、临界区、位操作）。
- `lib/include/ai8051u_sfr.h`：由 `tools/keil2sdcc.py` 自动生成，120 个可位寻址 SBIT +
  189 个掩码退化位 + 完整 XFR `__xdata` 指针定义 + 中断向量号。
- `tools/keil2sdcc.py`：Keil → SDCC 头翻译脚本（可重跑，跨平台 Python）。
- 验证：用本机 SDCC 4.5.20 `-mmcs51` 编译样例，退出 0；确认 `PIN_*` 生成 `setb/cpl`、
  `EAXSFR()` 生成 `orl _P_SW2,#0x80`、`ISR(TMR0_VECTOR)` 落在向量 0x000B。
  注：本机 SDCC 不支持 `-mmcs251`，AI8051U 的 251 目标需先编译 `sdcc-c251 --enable-mcs251-port`。

## I. HAL 移植（Keil -> SDCC）

> 本节原文即为中文，无英文对照。

工具：`tools/keil2sdcc_c.py`（只改代码、不动注释，保持字符串/块注释状态，跨平台 Python）。

转换规则：

- `void f(void) interrupt N` -> `void f(void) __interrupt(N)`
- `sbit NAME = PORT^n;` -> `__sbit __at(位地址) NAME;`（位地址 = SFR 地址 + n）
- `sfr NAME = 0xNN;` -> `__sfr __at(0xNN) NAME;`
- `typedef bit` / `bit` / `xdata` / `edata` / `code` / `far` / `reentrant`
  -> `__bit` / `__xdata` / `__code` / `__far` / `__reentrant`
- `#include "ai8051u.h"` -> `ai8051u_sfr.h`；`"intrins.h"` -> `mcs_intrins.h`
- Keil `char putchar(char)` -> SDCC `int putchar(int)`

关键语义差异（必须改写，不是关键字问题）：

- STC 251 核允许对**非 8 倍数地址的 SFR** 做位寻址（Keil `sbit ADC_CONTR^7`），
  SDCC 的 `__sbit` 只覆盖 0x80-0xFF 经典位空间，`ADC_POWER = 1` 无法直接编译。
  翻译器把这类名字（共 189 个）改写为字节操作：
  - `NAME = 1;`        -> `SFR |= mask;`
  - `NAME = 0;`        -> `SFR &= ~mask;`
  - `NAME = expr`      -> `SFR = (SFR & ~mask) | ((expr) ? mask : 0)`（含宏内无分号形式）
  - 其余 `NAME`（读）  -> `(SFR & mask)`
- `_nop_()` 必须是**表达式**（STC 的 `NOP2() NOP1(),NOP1()` 依赖逗号表达式），
  故 `mcs_intrins.h` 用内联函数 `mcs_nop_impl()` 实现。

结果：`lib/stc-hal/` 下 34 个 `.c` 与全部 `.h` 用本机 SDCC 4.5.20 `-mmcs51 --model-large`
编译全部通过（exit 0）。待 mcs251 端口就绪后再验证 251 目标。
