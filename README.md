# zig-mcs51-backend

让 **Zig 自举（self-hosted）编译器**直接产出 Intel **MCS-51（8051）**
的 ASxxxx 汇编（`.asm`），再交给 SDCC 的 `sdas8051` + `sdld` 汇编链接。

本仓库是上游 Zig 的分支工作树（当前基线 **Zig 0.17.1**），在其上新增 **`mcs2`** 后端（8051 方向）。
上一代的 MCS-251 后端在 0.16 分支（`src/codegen/mcs251-backend/`），本树只保留它的目标定义。
上游原有 README 已重命名为 [`README-zig.md`](README-zig.md)。

- 目标：8 位 8051 内核的 STC / AI 系列（已在 **AI8051U-34K64** 真机验证）
- 产物是**汇编文本**，不是目标码；交叉编译链沿用它已有的汇编器/链接器
- C 用 SDCC 编，Zig 用本后端编，两边同一套边界 ABI，可混编后链成同一份固件
- 所有值住在**静态 DSEG 槽**（每函数一块），因此调用不需要保存现场，代价是静态 RAM 吃紧（见「已知限制」）

## 现在能编什么

| 类别 | 支持 |
| --- | --- |
| 整数 | `u8/u16/u32`、`i8/i16/i32` 的加减、乘、除、取余、移位（常量/运行期次数）、比较、按位与或异或取反、符号扩展、`bool` |
| 调用 | 内部直调、**间接调用**（`*const fn`）、**函数指针表**、**尾调用**（`return f(x)` → `ljmp`，自递归编成循环） |
| 控制流 | `if`/`else`/`while`/`for`、**真 `switch`**（多 case、`1...5` 范围、`else`、`enum`，判定值 8 位）、**if/switch 表达式** |
| 数组 | 固定地址（`@ptrFromInt`）、全局/静态符号基址、**运行期指针**、**多维下标（≤4 维）**、**16 位下标**、`const` 常量表（初值进代码段，`movc` 读，一维） |
| 数据 | 多字节全局变量（`var g: u32` 读写/读改写/比较）、SFR 直址与位操作（SFR 位、`0x20–0x2F` 位区） |
| 中断 | ISR 属性函数（自动生成向量跳板，`reti` 收尾，现场保存可关） |
| 库 | CORDIC 定点数学（`sin/cos/atan2/sqrt32/hypot`，二进制角 + Q14，纯加减/算术右移） |

配套的验证与测量工具都在 `tools/mcs2/`（见下）。

## 提升表

口径：**函数体字节** = 首条指令 → 第一条 `RET`；mcs2 与 SDCC 走同一条 `sdas8051`+`sdld` 链，
Keil 读编译器 listing 的 `CODE SIZE`。三段代码见 `tools/mcs2/bench_c/`。

### 1. 与 SDCC 4.6 / Keil C51 的代码尺寸

七种「真程序里最常写的形状」，同一段语义：

| 用例 | mcs2 | SDCC 4.6 | Keil C51 | mcs2 / 最好 | mcs2 静态 DSEG | Keil DATA |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `switch`（3 case + default） | 40 | 32 | **27** | 1.48× | 7 B | 0 |
| 条件表达式（`c ? 0x11 : 0x22`） | 24 | 13 | **9** | 2.67× | 10 B | 0 |
| `const` 表查表 `t[i]` | 26 | 9 | **7** | 3.71× | 7 B | 0 |
| u16 表下标（scale=2，写读各一次） | 98 | **28** | 43 | 3.50× | 46 B | 0 |
| u32 表下标（scale=4，相邻两元素） | 393 | **110** | 147 | 3.57× | 48 B | 0 |
| 函数指针调用 `p(x)` | 30 | 21 | **9** | 3.33× | 17 B | 0 |
| CORDIC 定点 sin（12 次迭代） | 469 | **265** | 282 | 1.77× | 60 B | 0 |

**怎么读这张表**

1. **真算法只差 1.8×**（CORDIC），差距被循环摊薄；**小算子吃亏 2.7–3.7×**，
   固定开销（槽位中转、每次访问重算地址、间接调用的 push×4 + `ret`）在小函数里占满比例。
2. **表下标那一半是「重复算地址」**：mcs2 每访问一次元素就重算一遍 DPTR，
   SDCC/Keil 会把 `t[i]` 的地址留在 DPTR 里复用。这是已知的下一步。
3. **静态数据才是真瓶颈**（对比 Keil 的 `DATA` 列全是 0）：mcs2 每个函数一块静态槽，
   8051 的内部直接寻址 RAM 只有 0x30–0x7F 共 80 字节 —— 一个 CORDIC 就用掉 60 B。

### 2. 最近两轮优化的前后对比（同一台机器、同一套用例）

| 项目 | 优化前 | 优化后 | 变化 | 做了什么 |
| --- | ---: | ---: | ---: | --- |
| u32 表下标（单元素） | 442 | **186** | −58% | `scale=k` 改一次 `MUL AB` 拿完整 16 位积，不再重复 k 次「16 位加下标」 |
| u32 表下标（相邻两元素） | 905 | **393** | −57% | 同上 |
| u16 表下标（单元素） | 130 | 98 | −25% | 同上 |
| u16 表下标（相邻两元素） | 275 | 211 | −23% | 同上 |
| 全局数组下标（符号基址） | 166 | 110 | −34% | 符号 + 常量偏移折进重定位：`mov dptr,#(_sym+0x0012)`（15 B → 3 B） |
| `const` 表查表 | 87 | 59 | −32% | 同上 |
| CORDIC sin | 494 | 469 | −5% | 槽位复用（临时槽/结果槽回收） |
| CORDIC 的静态 DSEG | 74 | **60** | −19% | 同上 |

### 3. 复现

```bash
# 示例/用例：一个 build.zig 编出全部 49 个 .asm（宿主 zig 跑脚本，mcs2 编代码）
cd examples/mcs51 && zig build -Dzig=../../zig-out/bin/zig

# 验收与测量
cd ../../tools/mcs2
python mcs2.py check            # 135 项仿真验收（ucsim 8052）
python bench_compare.py         # 生成上表（需要 SDCC bin；Keil 可选，设 KEIL_BIN 或自动发现）
python fwsize.py                # 另一套口径：整份固件（含被拉进来的库）
```

## 构建

本仓库的编译器**用系统 Zig 构建**（自举），产物是新的 `zig`：

```bash
# <repo> 为本仓库根目录；构建时要用本树的 std（含 mcs51/mcs251 目标定义）
export ZIG_LIB_DIR=<repo>/lib
zig build -Doptimize=ReleaseFast -Dno-lib --zig-lib-dir <repo>/lib
# 产物：<repo>/zig-out/bin/zig
```

`-Dno-lib` 跳过把 `lib/` 复制进安装目录（开发时省时间）；产物可直接用，
**运行前仍要 `ZIG_LIB_DIR=<repo>/lib`**（`lib/` 里有 `mcs51`/`mcs251` 目标定义）。

## 用法

```bash
zig build-obj -target mcs51-freestanding -femit-bin=out.asm in.zig
```

汇编与链接（ASxxxx）：

```bash
sdas8051 -plosgffw out.rel out.asm
sdld -f out.lk          # 链接脚本里指定 CSEG/DSEG 起点
```

## 最小示例

```zig
// 写 SFR 0x90（P1），并演示一个带索引的表
const T: *[8]u16 = @ptrFromInt(0x8200);

export fn main() void {
    var a: u8 = 7;
    a = a +% 3;
    @as(*volatile u8, @ptrFromInt(0x90)).* = a;   // P1 = 10
    T[3] = 0x1234;
}
```

三维数组（屏幕帧缓冲这类）也能直接写，多维步长自动按各维乘积算：

```zig
const FB: *[2][32][64]u16 = @ptrFromInt(0x2000);

export fn px(z: u8, y: u8, x: u8, c: u16) void {
    FB[z][y][x] = c;       // 地址 = 基址 + z*4096 + y*128 + x*2
}
```

## 目录

| 路径 | 说明 |
| --- | --- |
| `src/codegen/mcs2.zig` | 后端主体：AIR → 中间表示（MIR），槽位分配、ABI、调用、下标、switch 全在这里 |
| `src/codegen/mcs2/mir.zig` | 极小的 MIR 指令集（一条指令 = 一段固定汇编模板） |
| `src/codegen/mcs2/mcs51.zig` | MIR → 8051 汇编发射器（DPTR 复用、跳转松弛、位地址换算） |
| `src/link/Asx.zig` | ASxxxx 链接抽象（全局变量与 `const` 表的数据发射） |
| `examples/mcs51/` | **全部示例与验收用例**：`src/*.zig`（48 个文件 / 135 项）、`lib/cordic.zig`、统一的 `build.zig` |
| `tools/mcs2/` | 验收驱动（编译→汇编→链接→ucsim 比对）、三方尺寸对比、能力探针、真机脚本 |

## 已知限制

- **非尾递归不安全**：参数走静态 `PARM` 槽，内层调用会覆盖外层；尾递归已编成循环（安全）。
- **没有浮点**：按设计交 STC 官方浮点库（C 侧）处理，后端只保证定点/整数。
- `switch` 判定值限 **8 位**（256 种命令够用）；更大的命令字请用「字节表 + 函数指针表」二级分派。
- `const` 表**只有一维**；多维 `const` 表暂不支持。
- `var` 的**初值不装载**（XRAM 掉电即失，装载要走启动拷贝）；查表请用 `const`。
- **饱和算术**（`+|`/`-|`/`*|`）未实现，会明确报错。
- **ISR 里不要放带局部量的代码**（ISR 不走 epilogue，会漏栈）；逻辑放进普通函数再调用。
- 静态 RAM（DSEG）紧张：8051 只有 80 字节可直址，一个稍大的算法就能吃光 —— 见上表最后一列。

## 验证

- **仿真**：135 项用例，经 `sdas8051`+`sdld` 链成 `.ihx` 后在 ucsim-51（8052 模式）里读回 xdata 判定。
- **真机**：129 项 / 42 组固件（`tools/mcs2/realcheck.py`）在 AI8051U-34K64（8 位模式）上跑通；
  同一套脚本也能无板自检（`--sim`，与仿真用例共用同一份 `.ihx`）。
- **三方对照**：`bench_compare.py` / `fwsize.py` 随时重算上面两张表；
  对比源码集中在 `examples/compare/c/{sdcc,keil}/`，25 例结果见 `docs/对比-全部示例-2026-11-02.md`。

## 与上游 Zig 的差异

本树在基线（Zig 0.17.1）之上加的东西：

| 路径 | 改动 |
| --- | --- |
| `src/codegen/mcs2.zig`、`src/codegen/mcs2/` | **新增**：AIR → MIR → 8051 汇编的后端 |
| `src/link/Asx.zig` | **新增**：ASxxxx 链接抽象（全局变量与 `const` 表的数据发射） |
| `lib/std/Target/mcs51.zig` 等 | mcs51/mcs251 目标定义（基线里已含） |
| `src/link/Coff.zig` | **放宽** COFF weak external 的 `value` 校验：规范要求 0，但自举时生成的 `compiler_rt.lib` 写入了非零值，严格校验会让本编译器连自己的 build runner 都链不出来（`zig build` 因此不可用） |

宿主侧能力现在是通的：本仓库编出来的 `zig` 可以直接跑 `zig build`（见 `examples/mcs51`）。

## 许可

与上游一致：MIT（见 [`LICENSE`](LICENSE)）。
