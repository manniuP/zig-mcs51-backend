# zig-mcs51-backend

让 **Zig 自举（self-hosted）编译器**直接产出 Intel 8051（MCS-51）/ 80251（MCS-251）的
ASxxxx 汇编（`.asm`），再由 SDCC 的 `sdas251` / `sdas8051` 汇编、链接。

本仓库是上游 Zig 的分支工作树（基线 commit `7056ba9a5c`，版本 `0.16.1-dev`），在其上新增
MCS-51/MCS-251 后端。上游原有 `README.md` 已重命名为 [`README-zig.md`](README-zig.md)。

- 目标芯片：STC / AI 系列（已在 **AI8051U-34K64** 真机验证）
- 产出：ASxxxx 汇编文本；C 由 SDCC 编译，Zig 由本后端编译，最后用 `sdas` + `sdld` 链成同一固件
- 生成的汇编内夹带 `; vN …` 形式的 IR 提示，供构建层优化器（汇编瘦身 / 死代码回收）使用

## 构建（用系统 zig 0.16.0）

```powershell
# <repo> 为本仓库根目录
zig build -Doptimize=ReleaseFast -Dno-lib -Dmcs-only --zig-lib-dir <repo>\lib
# 产物：<repo>\zig-out\bin\zig.exe
```

运行前把 `ZIG_LIB_DIR` 指向本树 `lib/`（内含 `mcs51`/`mcs251` 目标定义）：

```powershell
$env:ZIG_LIB_DIR = "<repo>\lib"
```

`-Dmcs-only` 只编入 MCS 后端（跳过 x86_64 等巨大后端的分析，构建更快）；省略该选项即得到
完整多后端编译器。

## 使用

```powershell
zig build-obj -target mcs251-freestanding -femit-bin=out.asm in.zig
zig build-obj -target mcs51-freestanding  -femit-bin=out.asm in.zig
```

示例（写 SFR `0x90` = P1）：

```zig
export fn main() void {
    var a: u8 = 7;
    const b: u8 = 3;
    a = a +% b;
    @as(*volatile u8, @ptrFromInt(0x90)).* = a;
}
```

生成的是 ASxxxx 语法汇编，交给 SDCC 汇编器：

```powershell
sdas251  -o out.rel out.asm      # MCS-251
sdas8051 -o out.rel out.asm      # MCS-51
```

## 关键实现位置

| 路径 | 说明 |
| --- | --- |
| `src/codegen/mcs/` | MCS-51/251 自举后端（`CodeGen`、`Mir`、`abi`、`encode`、`forms`、`device`） |
| `src/link/Asx.zig` | ASxxxx 链接抽象 |
| `lib/std/Target/{mcs51,mcs251}.zig` | 目标定义 |
| `src/{target,codegen,Type,Sema,Zcu,link,dev}.zig` | 接入点 |
| `build.zig` | 仅新增 `-Dmcs-only`，其余保持上游完整功能 |

## 验证状态

- 用系统 zig 0.16.0 构建本分支编译器：通过
- `-target mcs251-freestanding` / `mcs51-freestanding` 生成汇编：通过（EXIT=0）
- `sdas251` / `sdas8051` 汇编成 `.rel`：通过（EXIT=0）
- 对应后端已在 AI8051U-34K64 真机跑通 GPIO / UART / 定时器中断 / 二进制日志等示例

## 许可

沿用上游 Zig 的 MIT 许可，见 [`LICENSE`](LICENSE)。

## 实验分支 `opt-tags`

本分支额外提供「**数据放置标签 + GCC 对齐优化等级（`O0`–`O3`/`Ofast`/`Os`）**」的后端更新，
并附带一个**自包含实验构建**（见 [`experimental/README.md`](experimental/README.md)）：

- 更新说明、示例（**标签优化测试示例** `ai8051u_zig_opt`）、全部 `docs/`、构建层工具与设备表；
- `experimental/build.ps1`：用系统 zig 构建本编译器 + 示例，后处理工具**直接跑 Python**（不冻成二进制）；
- 实验性内容**不进入 `mcs251` 分支**。
