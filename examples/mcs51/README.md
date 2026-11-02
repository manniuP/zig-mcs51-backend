# mcs2 示例与验收用例（MCS-51 / 8051）

> 本目录既是**示例**也是**验收用例**：`src/` 里每个 `.zig` 是一个可以单独编译的小程序，
> `tools/mcs2` 把它们当验收用例跑（编译 → sdas8051 → sdld → ucsim 读回 xdata）。

## 构建

直接用**本仓库编出来的编译器**跑构建脚本（它就是 mcs2 编译器）：

```bash
cd examples/mcs51
ZIG_LIB_DIR=<repo>/lib <repo>/zig-out/bin/zig build              # 全部 49 个 → zig-out/asm/*.asm
ZIG_LIB_DIR=<repo>/lib <repo>/zig-out/bin/zig build -Dcase=add   # 只编一个
```

也可以用系统 zig 跑脚本、用 `-Dzig=` 指定 mcs2 编译器（两者都能用；默认 `-Dzig` = 当前 zig）。

产物是 **ASxxxx 汇编文本**，不是目标码 —— 后面还要：

```bash
sdas8051 -plosgffw add.rel add.asm
sdld -f add.lk        # 链接脚本里指定 CSEG / DSEG 起点
```

## 用例清单

`cases.txt` —— 一行一个用例名（= `src/<名字>.zig`），`build.zig` 用 `@embedFile` 读它。
新增用例时要同步加一行（`tools/mcs2` 的用例表也要登记，见 `mcs2.py` 的 `CASES`）。

## 验收入口

```bash
cd ../../tools/mcs2
python mcs2.py check        # 133 项：编译 + 汇编 + 链接 + ucsim 读回比对
python mcs2.py check add    # 只跑某个用例
```

## 目录

| 路径 | 说明 |
| --- | --- |
| `src/` | 用例源码；文件名即用例组名 |
| `lib/cordic.zig` | 定点数学库，用例里 `@import("cordic")` |
| `cases.txt` | 用例清单（`build.zig` 的输入） |
| `tools/airdump.zig` | AIR 转储探针（函数名以 `_airdump` 结尾，编译时把 AIR 打到 stderr）；不进默认构建 |
| `build.zig` | 统一构建入口 |

## 为什么 build.zig 由宿主 zig 跑

mcs2 这棵树目前**跑不了 build runner**：宿主 `build-exe` 的链接会卡在 compiler_rt
归档解析上（COFF weak external 校验）。所以「跑构建脚本」交给宿主 zig（0.17.x），
「编 8051 代码」交给 mcs2 —— 两者通过 `-Dzig=` 连接。等宿主编译链修好，可以改回
`b.addObject` 的直接写法。
