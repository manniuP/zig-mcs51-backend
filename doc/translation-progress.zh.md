# Zig 编译器注释翻译进度

记录时间：2026-09-13
目标：把 Zig 自举编译器（`src/`）中**与指令集移植相关**的注释翻译为中文，采用**双语对照**、
**原地修改**（英文原注释后追加 `///` 中文翻译）。同时产出一份架构移植文档。

范围约定（用户指示）：
- 只在注释中追加中文，不修改任何代码。
- 与架构移植**无关**的内容不翻译（前端 Sema 内部、增量编译依赖/引用簿记、序列化、
  源位置枚举等）。

---

## 1. 已完成

### 1.1 文档（新文件）

- `doc/instruction-set-porting.zh.md`
  - 编译器管线：ZIR → AIR → MIR → 机器码 + 重定位 → 目标文件
  - 后端接口契约（`codegen.zig`：`importBackend` / `AnyMir` / `generate` / `emit`）
  - 参考后端 aarch64 分层：`Select` / `encoding` / `Mir` / `abi` / `Assemble`
  - 链接层与重定位、目标描述（`target.zig` / `std.Target`）、`dev.zig` 门控
  - 新增一个指令集后端的**分阶段清单**与“最常改的 10 个文件”

### 1.2 双语注释（原地修改）

| 文件 | 内容要点 | 状态 |
|---|---|---|
| `src/codegen.zig` | 后端分发器、`AnyMir`、`generateFunction`/`emitFunction`、`MCValue`、`LowerResult`、值/符号 lowering | ✅ |
| `src/codegen/aarch64.zig` | 后端入口（参数 caller→callee 转换、入口登记） | ✅ |
| `src/codegen/aarch64/Mir.zig` | 无注释 | ✅ 无需翻译 |
| `src/codegen/aarch64/abi.zig` | AAPCS64 类型分类 | ✅ |
| `src/codegen/aarch64/Select.zig` | 块/值跟踪、栈帧布局、循环活跃性、合并算法、调用 ABI（含 AAPCS64 章节标注） | ✅ |
| `src/target.zig` | 后端选择、函数对齐、ABI、栈保护、地址空间、PIC/PIE 等 | ✅ |
| `src/Air.zig` | 全部 `Inst.Tag` 指令语义、`Data` 联合与载荷结构、`Index`/`Ref`、`mustLower`、`CompilerRtFunc` 表 | ✅ |
| `src/Value.zig` | 值的内存读写、ABI 读写、比较、指针派生、`interpret`/`uninterpret` | ✅ |
| `src/Type.zig` | `Class` 分类、`hasRuntimeBits`/`abiSize`/`abiAlignment`、字段布局、指针/联合/枚举类型查询、`unpackable`/`validateExtern` | ✅ |
| `src/InternPool.zig` | 依赖管理（`AnalUnit`/`DepEntry`/`Local`）、`Nav`、`TrackedInst`、`NullTerminatedString`、`CaptureValue`、**`Key` 全部类型**、`Tag`、`Index`、`SimpleType`/`SimpleValue`/`Alignment` | ✅（核心） |
| `src/Zcu.zig` | `Feature`（后端多线程契约）、`callconvSupported`、`atomicPtrAlignment`、头部与关键字段 | ✅（移植相关部分） |
| `src/Air/Legalize.zig` | 后端可启用的全部合法化特性（scalarize/expand/soft_float/packed 等） | ✅（Feature 文档） |
| `src/Air/Liveness.zig` | tomb 位、`CondBr`/`SwitchBr`/`Block`、两趟分析 | ✅ |
| `src/Air/Verify.zig`、`src/Air/Liveness/Verify.zig`、`src/Air/print.zig` | 校验与打印说明 | ✅ |

统计（`git diff --stat`，仅注释插入）：

```
 15 files changed, 1891 insertions(+), 129 deletions(-)
```

> 说明：`Insertions/Deletions` 包含“英文原行改为英文+中文”，因此 deletions 非零，但
> 实际未改动任何代码。

---

## 2. 已跳过（移植无关，按用户要求）

- `src/encoding.zig`（aarch64 专用，ARM 手册章节引用，新 ISA 用不到）
- `src/codegen/aarch64/encoding.zig` 与 `Assemble.zig`/`Disassemble.zig`（Assemble/Disassemble 无注释）
- `src/Sema.zig` 与 `src/Sema/`（前端语义分析，移植时不改）
- `src/Zcu/PerThread.zig`（语义/增量辅助）
- `src/InternPool.zig` 中的序列化、`encodings` 表、trailing 数据布局等簿记注释
- 增量编译依赖/引用图、`LazySrcLoc` 源位置枚举、Wasm/SPIR-V 等非目标平台专用代码

如需补译，可从上述任一文件继续；翻译与否不影响编译。

---

## 3. 验证方式

对每个改动文件运行：

```
zig ast-check <file>
```

结果：除 `@divCeil` 报错外全部通过。`@divCeil` 报错在**改动前的原始文件**中同样存在
（本机 Zig 0.16 与仓库所用语言版本的差异），与注释改动无关。

---

## 4. 未提交

所有改动尚未 `git commit`，也未暂存。新增文件：`doc/instruction-set-porting.zh.md`、
本进度文件 `doc/translation-progress.zh.md`。

---

## 5. 花费

截至本记录，API 花费约 **1.5 元**（用户口径）。
