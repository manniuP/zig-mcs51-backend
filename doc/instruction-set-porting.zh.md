# Zig 编译器后端架构与指令集移植指南

本文面向“把 Zig 自举编译器移植到一个新的指令集（ISA）”的场景，说明从源码到机器码的
完整数据流、自举后端的接口契约、参考后端（aarch64）的分层结构，以及新增一个后端需要
触碰的所有位置。文档以当前仓库中的自举（self-hosted, stage2）后端为准；LLVM 后端只作为
对照。

术语约定：本文保留英文专有名词（AIR、MIR、InternPool、Nav、UAV、ZIR 等），正文用中文。

---

## 1. 总览：从源码到机器码

```
 .zig 源码
    │  (AstGen)
    ▼
 ZIR        —— 每个文件一份，未解析、基于指令的中间表示
    │  (Sema / AstGen 的解析与类型检查)
    ▼
 AIR        —— 每个函数一份，已解析类型、仍与机器无关
    │            (Air.zig)
    ▼
 MIR        —— 每个函数一份，机器相关；由具体后端的 Select 阶段产生
    │            (codegen/<arch>/Mir.zig)
    ▼
 机器码字节 + 重定位 —— 由 Mir.emit() 写入 link.File
    │            (link.zig / link/*)
    ▼
 目标文件 (.o) / 可执行文件
```

关键边界：

- **ZIR → AIR**：由 `Sema` 完成语义分析并生成 AIR。这一层与 ISA 完全无关，移植新
  指令集**不需要**改动。
- **AIR → MIR**：由后端（`src/codegen/<arch>/`）完成指令选择、寄存器分配、栈布局。
  **这是移植工作的核心**。
- **MIR → 字节**：`Mir.emit()` 负责把指令编码成字节，并把符号/重定位交给
  `link.File`（ELF / Mach-O / COFF / Wasm / SPIR-V 等）。多数工作可复用，只需提供
  指令编码与重定位类型映射。

因此，一个“新指令集后端”的最小实现 = 一个能把 AIR 翻译为该 ISA 指令（MIR）的
`Select`，加上该 ISA 的指令编码/解码和重定位映射。

---

## 2. 目录结构

```
src/
  Air.zig                 机器无关的 AIR 定义
  Sema.zig                ZIR -> AIR，语义分析（与 ISA 无关）
  InternPool.zig          全局驻留池：类型、值、Nav、UAV 去重
  Type.zig / Value.zig    类型与值
  Zcu.zig                 Zig 编译单元（取代旧的 Module）
  Compilation.zig         一次编译的顶层驱动
  target.zig              “目标平台相关”的编译期策略集合
  dev.zig                 开发环境/功能门控（哪些后端被编进当前构建）
  codegen.zig             后端分发器 + 后端接口契约 + 通用常量/符号 lowering
  codegen/
    aarch64.zig           aarch64 后端入口（generate/emit/legalizeFeatures）
    aarch64/
      Select.zig          AIR -> MIR：指令选择 + 寄存器分配
      Mir.zig             MIR 数据结构 + emit(MIR -> 字节 + 重定位)
      encoding.zig        指令编码/解码（含指令表）
      instructions.zon    指令定义数据
      abi.zig             调用约定类型分类（AAPCS64）
      Assemble.zig        汇编器（文本汇编 -> MIR/字节）
      Disassemble.zig     反汇编器
    x86_64/               旧的 x86_64 单体后端（CodeGen.zig 巨大）
    riscv64/ sparc64/ wasm/ spirv/ c/ llvm/
  link.zig               链接器抽象；link/ 下为 ELF/Mach-O/COFF/Wasm/SPIR-V 实现
```

`aarch64` 后端是**新式、分层清晰**的后端，是移植时最值得照抄的模板；`x86_64/CodeGen.zig`
是历史单体实现，不建议作为模板。

---

## 3. 后端分发器与接口契约（`src/codegen.zig`）

`codegen.zig` 是“编译器其余部分”与“具体后端”之间唯一的契约面。核心结构：

### 3.1 后端选择

```zig
pub fn zigBackend(target: *const std.Target, use_llvm: bool) std.lang.CompilerBackend
```

位于 `src/target.zig`。它根据 `target.cpu.arch` 决定用哪个后端。新 ISA 需要在这里新增
一个 `stage2_<arch>` 分支（或复用 `stage2_c` 后端作为过渡）。

### 3.2 导入后端

```zig
fn importBackend(comptime backend: std.lang.CompilerBackend) type
```

把 `std.lang.CompilerBackend` 标签映射到具体 Zig 类型。新增后端时要在此登记。

### 3.3 后端必须实现的功能

| 函数 | 位置 | 职责 | 是否必须 |
|---|---|---|---|
| `legalizeFeatures(target) ?*const Air.Legalize.Features` | 后端入口 | 告诉 AIR 合法化阶段本后端支持哪些特性，`null` 表示使用默认 | 必须 |
| `generate(lf, pt, func_index, air, liveness) !Mir` | 后端入口 | AIR -> MIR，含指令选择与寄存器分配 | 必须 |
| `Mir.emit(mir, lf, pt, func_index, atom_index, w, debug_output) !void` | `Mir.zig` | MIR -> 字节 + 重定位 | 必须 |
| `generateLazy(...)` | 可选 | 延迟符号（编译器内置函数等） | 可选 |
| `wantsLiveness(pt, nav_index) bool` | `codegen.zig` | 是否需要活跃性分析；aarch64 返回 false | 可选 |

### 3.4 AnyMir：跨后端的 MIR 联合

```zig
pub const AnyMir = union { aarch64: ..., x86_64: ..., ... };
```

因为链接器需要在“不知道当前后端”的情况下处理 MIR，所以用联合把所有后端的 MIR 包起
来，tag 由后端决定。新增后端要在此加入自己的 `Mir` 类型，并在 `AnyMir.tag` 增加分支。

### 3.5 通用 lowering（多数可复用）

`codegen.zig` 里还有一批与 ISA 基本无关、处理“值/符号”的工具，移植时**大多可直接复用**：

- `generateSymbol` / `generateLazySymbol`：把编译期常量按 ABI 布局写成字节。
- `lowerValue` / `genTypedValue`：把 `Value` 降级为立即数 / 符号引用（返回 `LowerResult`）。
- `lowerPtr` / `lowerNavRef` / `lowerUavRef`：把指针、Nav、UAV 引用降级为符号引用。
- `errUnionPayloadOffset` / `errUnionErrorOffset` / `fieldOffset`：ABI 布局辅助。
- `MCValue` / `LowerResult`：降级结果。

新后端通常**不需要**重写这些，而是复用它们，只在 `emit` 阶段把 `LowerResult` 映射为
本 ISA 的重定位类型。

---

## 4. 参考后端：aarch64 的分层

`src/codegen/aarch64.zig` 是后端入口，主要做三件事：

1. 组装 `Select` 的初始状态（目标、AIR、Nav、各动态数组）。
2. 处理 **调用约定相关的前置工作**：参数从调用者寄存器/栈位置转换为被调用者视角、
   可变参数（varargs）的 `va_list` 布局、返回值位置。
3. 依次调用 `Select.analyze` / `finishAnalysis` / `body` / `layout`，最后汇总为一个
   `Mir`（prologue / body / epilogue / literals / 各类 reloc）。

随后链接器调用 `Mir.emit()`：

- 指令按“前半正向、后半反向”两种方式写入（见下文）。
- 遍历 `nav_relocs` / `uav_relocs` / `lazy_relocs` / `global_relocs` / `literal_relocs`，
  为每条重定位生成 ELF `R_AARCH64_*` 或 Mach-O relocation。

### 4.1 Select：AIR -> MIR

`Select.zig`（本仓库中最大，约 600KB）承担：

- **值模型**：`Select.Value` 表示一个虚拟值，可能位于寄存器、栈槽、常量或引用。
- **块与支配树**：`blocks`、`dom`、`dom_start/len`，用于跨块数据流。
- **活跃性**：`live_registers`、`live_values`、`loop_live`，用于寄存器分配。
- **指令选择**：把每条 AIR 指令翻译为一条或多条本 ISA 的 `Instruction`。
- **寄存器分配**：基于 hint/活跃区间分配物理寄存器，溢出到栈。
- **栈布局**：`stack_size`、`stack_align`，在 `layout` 中生成 prologue/epilogue。

移植时应重点理解它的“分析 -> 定点迭代分析 -> 生成 body -> layout”四阶段结构，然后
按同一骨架为新 ISA 实现。不同 ISA 的差异集中在：值类型到寄存器类的映射、指令选择表、
寻址模式、立即数范围、分支/条件码。

### 4.2 encoding：指令编码/解码

`encoding.zig` + `instructions.zon` 定义本 ISA 的每条指令及其编解码。移植时需要为
新 ISA 准备等价物：指令位域定义、`Instruction` 类型、`decode()`、`write()`。对于定长
指令（如 aarch64 的 32 位），`Instruction.size` 是常量；变长指令集（x86）则更复杂。

### 4.3 Mir：MIR 容器与 emit

`Mir.zig` 定义：

```zig
prologue: []const Instruction,
body:     []const Instruction,
epilogue: []const Instruction,
literals: []const u32,
nav_relocs / uav_relocs / lazy_relocs / global_relocs / literal_relocs
```

注意 aarch64 后端的 `body` 在内存中是**倒序**存放、`emit` 时反向写出的（这是该后端的一个
实现细节，用于简化某些跳转偏移计算）。新后端可以自由选择布局，只要 `emit` 自洽。

`emit` 的职责：计算函数对齐与字面量对齐间隙、写指令、写字面量、对每条重定位调用
`atom.addReloc` 并给出本平台的重定位类型。

### 4.4 abi：调用约定

`abi.zig` 实现 AAPCS64 的类型分类（`.memory` / `.byval` / `.integer` /
`.double_integer` / `.float_array`）。新 ISA 需要实现自己的 ABI 分类与传参/返回规则，
并在 `aarch64.zig` 对应位置（参数搬运、`va_list`、返回值）实现等价逻辑。

### 4.5 Assemble / Disassemble

`Assemble.zig` 把文本汇编解析为 MIR/字节，`Disassemble.zig` 反向。它们主要用于
`zig build-obj` 之外的场景和测试；移植时优先级最低，可先留空/后补。

---

## 5. 链接层

`src/link.zig` 定义 `link.File` 抽象，`src/link/` 下是实现（`Elf`、`MachO`、`Coff`、
`Wasm`、`Spirv`、`C`）。

后端与链接层的交互点：

- `lf.lowerUav(pt, val, align)` / `lf.getUavVAddr(...)`：UAV（未命名匿名值）地址。
- `lf.getNavVAddr(pt, nav_index, ...)` / `genNavRef`：Nav（具名值/函数）符号。
- `atom.addReloc(...)`：把重定位写入正在生成的目标文件对象。
- `generateLazySymbol` / `lf.lowerUav`：延迟符号。

移植策略：**优先复用现成链接器**（通常目标 ISA 的平台就是 ELF 或 Mach-O）。你只需要
在 `Mir.emit` 里为新 ISA 选择正确的重定位类型枚举（如 `std.elf.R_<ARCH>_*`），链接器
本身一般无需改动。只有当新平台引入新的目标文件格式或新重定位时，才需要扩展 `link/`。

---

## 6. 目标平台描述与 CPU 特性

与 ISA 相关的“策略”集中在 `src/target.zig`，以及标准库的 `std.Target`（在
`lib/std/Target.zig` 与生成的 `std.Target.<arch>` 中）。新增指令集通常要：

1. 在 `std.Target.Cpu.Arch` 增加枚举值（若基座尚未支持该 arch）。
2. 提供该 arch 的 CPU 型号、特性枚举、默认特性集合。
3. 在 `src/target.zig` 的若干 `switch (target.cpu.arch)` 中补分支，例如：
   - `zigBackend`：选择后端；
   - `defaultFunctionAlignment` / `minFunctionAlignment`；
   - `hasRedZone` / `functionPointerMask` / `supportsReturnAddress`；
   - `hasValgrindSupport` / `hasLlvmSupport` 等。
4. 若使用 LLVM 后端过渡，还需要 triple / `llvmMachineAbi` 等映射。

一个现实做法是：**先让新 ISA 走 `stage2_c` 后端或 LLVM 后端跑通语言特性，再逐步实现
自举后端**。`target.zig::selfHostedBackendIsAsRobustAsLlvm` 等函数决定了 debug 模式下
是否优先用自举后端。

---

## 7. 开发环境门控（`src/dev.zig`）

Zig 编译器会被裁剪成不同的“开发环境”（`dev.Env`），例如 `core`、`sema`、
`aarch64-linux`，每个环境只包含一部分 `Feature`。新增后端需要：

1. 在 `dev.Feature` 增加 `<arch>_backend`。
2. 在相应 `dev.Env.supports` 中放行该 feature。
3. 在 `codegen.zig` 用 `dev.check(devFeatureForBackend(backend))` 在入口处静态断言。

否则新后端的代码根本不会被编进二进制，或者构建时报“不支持该 feature”。

---

## 8. 移植新指令集：分步清单

以下按“先能跑通，再优化”的顺序给出建议步骤。

### 阶段 A：目标描述
1. 在 `std.Target` 增加 arch（若需要）。
2. `src/target.zig::zigBackend` 映射到新后端标签。
3. `dev.zig` 增加 `<arch>_backend` feature 与 env 放行。
4. 先用 LLVM/C 后端作为回退，确保前端语言特性可编译。

### 阶段 B：后端骨架
5. 新建 `src/codegen/<arch>.zig`（入口）与 `src/codegen/<arch>/` 目录。
6. 在 `codegen.zig` 的 `importBackend`、`AnyMir`、`AnyMir.tag`、`emitFunction` 登记。
7. 定义 `Mir.zig`：指令切片、字面量、各类 reloc。
8. 实现一个**最小 `Select`**：只支持函数返回常量、整数算术；不做寄存器分配时可以先
   “每个值都放栈槽”的朴素分配。

### 阶段 C：指令编码与 emit
9. 定义 `encoding.zig` 与指令表（可由表格生成，参考 `instructions.zon`）。
10. 实现 `Mir.emit`：写指令字节，为每个符号引用选出正确的重定位类型。
11. 通过 ELF 的 `genNavRef` / `atom.addReloc` 打通到目标文件。

### 阶段 D：调用约定与 ABI
12. 实现 ABI 类型分类与参数/返回值传递。
13. 实现栈帧布局：prologue/epilogue、栈对齐、被调用者保存寄存器。
14. 实现可变参数。

### 阶段 E：语言特性覆盖
15. 结构体/数组/切片的内存布局与按值传递。
16. 浮点/向量（若 ISA 支持）、错误联合、可选类型。
17. 原子操作、内联汇编、`@returnAddress`、栈探测/保护等 target 相关特性。
18. 与 `target.zig` 中 `supportsStackProbing` / `supportsStackProtector` /
    `supportsThreads` 等函数对齐。

### 阶段 F：收尾
19. 实现 `Assemble` / `Disassemble`。
20. 跑行为测试（`test/behavior`）并对照 `selfHostedBackendIsAsRobustAsLlvm` 的门槛。
21. 补充 `compiler_rt` / `libc` 的目标支持（若需要）。

---

## 9. 关键数据结构速查

- **`InternPool`**：全局去重池。类型（`Type`）、值（`Value`）、具名值（`Nav`）、
  未命名匿名值（`UAV`）、字符串/错误名等都存这里，用 `Index` 引用。后端大量函数接收
  `InternPool.Index`。
- **`Air`**：函数体是 `Air.instructions`（tag 数组 + data 数组）+ 一个指令索引序列。
  `air.getMainBody()` 返回主块指令列表。
- **`Type`**：包装 `InternPool.Index` 的轻量类型。`ty.abiSize(zcu)`、
  `abiAlignment(zcu)`、`hasRuntimeBits(zcu)`、`zigTypeTag(zcu)` 等是后端最常用的查询。
- **`Value`**：编译期值，`val.toIntern()` 得到池索引，`val.isUndef(zcu)` 等。
- **`Zcu` / `Zcu.PerThread`**：编译单元与线程上下文；几乎所有查询都通过 `pt.zcu`。
- **`link.File`**：目标文件/可执行文件的抽象，提供符号与地址。

---

## 10. 验证与调试

- `zig build test-behavior` / `test/behavior`：行为测试是判断后端正确性的主要标准。
- `zig build test-compiler-rt`、`test-std` 等。
- `print_zir.zig` / `print_zoir.zig`：打印中间表示，定位前端问题。
- `tracy.zig`：性能剖析插桩。
- `Disassemble.zig` 与链接器产物可用系统反汇编器交叉验证。
- `Air.Legalize`：在 AIR 层按 `legalizeFeatures` 的结果做合法化，尽量把“后端不支持的
  操作”在 AIR 层拆解，减轻后端负担。

---

## 11. 移植时最常改的 10 个文件

1. `src/target.zig` —— 后端选择与目标策略
2. `src/dev.zig` —— 后端 feature 门控
3. `src/codegen.zig` —— `importBackend` / `AnyMir` / 分发
4. `src/codegen/<arch>.zig` —— 后端入口
5. `src/codegen/<arch>/Mir.zig` —— MIR 与 emit
6. `src/codegen/<arch>/Select.zig` —— 指令选择 + 寄存器分配
7. `src/codegen/<arch>/encoding.zig` —— 指令编码
8. `src/codegen/<arch>/abi.zig` —— 调用约定
9. `src/codegen/<arch>/Assemble.zig` / `Disassemble.zig`
10. `lib/std/Target.zig` 及对应 `<arch>` 目标描述（若 arch 尚未存在）

---

## 12. 备注

- 本文基于当前工作树（`src/` 下 `codegen/` 已拆分为 aarch64 / x86_64 / riscv64 /
  sparc64 / wasm / spirv / c / llvm）。不同版本目录结构可能不同，请以实际代码为准。
- 文档中的代码位置以 `src/codegen.zig`、`src/codegen/aarch64.zig`、
  `src/codegen/aarch64/Mir.zig`、`src/codegen/aarch64/abi.zig`、`src/target.zig`、
  `src/dev.zig` 为准，这些文件的注释已同步翻译为中文（双语对照），可作为逐行参考。
