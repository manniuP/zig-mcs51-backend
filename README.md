# zig-mcs51-backend

让 **Zig 自举（self-hosted）编译器**直接产出 Intel **MCS-51（8051）** 的 ASxxxx 汇编（`.asm`），
再交给 SDCC 的 `sdas8051` + `sdld` 汇编链接。

本仓库是上游 Zig 的分支工作树（基线 **Zig 0.17.1**），在其上新增 **`mcs2`** 后端（8051 方向）。
上一代 MCS-251 后端在 0.16 分支（`src/codegen/mcs251-backend/`），本树只保留它的目标定义。
上游原有 README 见 [`README-zig.md`](README-zig.md)。

- 目标：8 位 8051 内核的 STC / AI 系列（已在 **AI8051U-34K64** 真机验证）
- 产物是**汇编文本**，不是目标码；汇编/链接沿用 toolchain 里现成的
- C 用 SDCC 编、Zig 用本后端编，两边同一套边界 ABI，可混编成同一份固件
- 所有值住在**静态 DSEG 槽**（每函数一块）：调用不用保存现场，代价是静态 RAM 吃紧

## 现在能编什么

| 类别 | 支持 |
| --- | --- |
| 整数 | `u8/u16/u32`、`i8/i16/i32` 的加减、乘、除、取余、移位（常量/运行期次数）、比较、按位与或异或取反、符号扩展、`bool` |
| 调用 | 内部直调、**间接调用**（`*const fn`）、**函数指针表**、**尾调用**（`return f(x)` → `ljmp`，自递归编成循环） |
| 控制流 | `if`/`else`/`while`/`for`、**真 `switch`**（多 case、`1...5` 范围、`else`、`enum`，判定值 8 位）、**if/switch 表达式** |
| 数组 | 固定地址（`@ptrFromInt`）、全局/静态符号基址、**运行期指针**、**多维下标（≤4 维）**、**16 位下标**、`const` 常量表（初值进代码段、`movc` 读，一维） |
| 数据 | 多字节全局变量读写/读改写/比较、SFR 直址与位操作（SFR 位、`0x20–0x2F` 位区） |
| 中断 | ISR 属性函数（自动生成向量跳板、`reti` 收尾、现场保存；B 也保存） |
| 库 | CORDIC 定点数学（`sin/cos/atan2/sqrt32/hypot`，二进制角 + Q14，纯加减/算术右移） |

## 尺寸与周期对比

口径：**函数体字节** = 首条指令 → 第一条 `RET`；**周期** = 同一张 8051 周期表折算的静态值
（`tools/mcs2/cycles51.py`，条件跳转取最小、`lcall` 不含被调方）。
对比用的 C 源码在 [`examples/compare/c/`](examples/compare/)（SDCC / Keil 方言分文件夹），
**全量 25 例**见 [对比-全部示例](docs/对比-全部示例-2026-11-02.md)。

| 用例 | mcs2 | SDCC 4.6 | Keil C51 | 周期 mcs2 | 周期 SDCC | 周期 Keil | mcs2 DSEG | Keil DATA |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `switch`（3 case + default） | 40 | 32 | **27** | 21 | 13 | **12** | 7 B | 0 |
| 条件表达式 `c ? 0x11 : 0x22` | 24 | 13 | **9** | 14 | 8 | 8 | 10 B | 0 |
| `const` 表查表 `t[i]` | 26 | 9 | **7** | 18 | 8 | **6** | 7 B | 0 |
| u16 表下标（scale=2） | 98 | **28** | 43 | — | **25** | 32 | 46 B | 0 |
| u32 表下标（相邻两元素） | 393 | **110** | 147 | — | **114** | 84 | 48 B | 0 |
| 函数指针调用 `p(x)` | 30 | 21 | **9** | 22 | 16 | **6** | 16 B | 0 |
| CORDIC 定点 sin（12 次迭代） | 405 | **265** | 282 | 238 | **181** | 116 | 30 B | 0 |
| u32 乘法 | 144 | 15 | 27 | 89 | **8** | — | 22 B | 0 |

**怎么读**

1. **真算法只差 1.5×**（CORDIC，循环把固定开销摊薄）；**小算子吃亏 2.7–3.7×**。
2. **u16/u32 算术那两行不是同一件事**：SDCC/Keil 把乘除下沉到库（站点 3–15 B、8 周期），
   mcs2 每处内联整段模板（144 B、89 周期）。**调用点少时内联更省，多了库更省**。
3. **表下标一半是「重复算地址」**：mcs2 每访问一次就重算 DPTR，两家会把地址留在 DPTR 里复用。
4. **静态 RAM 才是真瓶颈**（Keil 那列全是 0）：8051 内部直址只有 80 字节，一个 CORDIC 就用 30 B。

### 优化前后（历史记录）

| 项目 | 优化前 | 优化后 | 变化 | 做了什么 |
| --- | ---: | ---: | ---: | --- |
| u32 表下标（单元素） | 442 | **186** | −58% | `scale=k` 改一次 `MUL AB` 拿完整 16 位积 |
| u32 表下标（相邻两元素） | 905 | **393** | −57% | 同上 |
| 全局数组下标（符号基址） | 166 | 110 | −34% | 符号 + 常量偏移折进重定位（15 B → 3 B） |
| `const` 表查表 | 87 | 59 | −32% | 同上 |
| CORDIC 静态 DSEG | 110 | **74** | −33% | 宽运算原地写回、临时槽按最后读取点回收、常量实参不落槽 |

## 快速开始

```bash
# 1) 编出本仓库的编译器（自举；依赖 PATH 里的系统 zig）
export ZIG_LIB_DIR=<repo>/lib
zig build -Doptimize=ReleaseFast -Dno-lib --zig-lib-dir <repo>/lib
# 产物 <repo>/zig-out/bin/zig，运行前仍需 ZIG_LIB_DIR=<repo>/lib

# 2) 编一个 .zig 成 8051 汇编
zig build-obj -target mcs51-freestanding -femit-bin=out.asm in.zig

# 3) 汇编 + 链接（ASxxxx）
sdas8051 -plosgffw out.rel out.asm
sdld -f out.lk            # 链接脚本里指定 CSEG/DSEG 起点
```

## 验收与测量

```bash
cd examples/mcs51 && zig build            # 全部用例 → zig-out/asm/*.asm（默认用 zig 自己）
cd ../../tools/mcs2
python mcs2.py check                      # 135 项仿真验收（sdas8051+sdld → ucsim-51）
python realcheck.py --sim                 # 真机脚本的无板自检（同一份 .ihx）
python realcheck.py --auto COMx --live <AiCube 装载的 .ihx>   # 真机全自动逐组烧录+收数
KEIL_BIN=<Keil>/C51/BIN python bench_compare.py                # 三方尺寸/周期对比
python fwsize.py                          # 另一套口径：整份固件（含被拉进来的库）
```

## 最小示例

```zig
// SFR 直址 + 一维表
const T: *[8]u16 = @ptrFromInt(0x8200);

export fn main() void {
    var a: u8 = 7;
    a = a +% 3;
    @as(*volatile u8, @ptrFromInt(0x90)).* = a;   // P1 = 10
    T[3] = 0x1234;
}
```

三维数组（帧缓冲这类）直接写，多维步长自动按各维乘积算：

```zig
const FB: *[2][32][64]u16 = @ptrFromInt(0x2000);

export fn px(z: u8, y: u8, x: u8, c: u16) void {
    FB[z][y][x] = c;       // 地址 = 基址 + z*4096 + y*128 + x*2
}
```

## 目录

| 路径 | 说明 |
| --- | --- |
| `src/codegen/mcs2.zig` | 后端主体：AIR → MIR，槽位分配、ABI、调用、下标、switch |
| `src/codegen/mcs2/mir.zig` | 极小的 MIR 指令集（一条指令 = 一段固定汇编模板） |
| `src/codegen/mcs2/mcs51.zig` | MIR → 8051 汇编发射器（跳转松弛、位地址换算） |
| `src/link/Asx.zig` | ASxxxx 链接抽象（全局变量与 `const` 表的数据发射） |
| `examples/mcs51/` | 全部示例与验收用例：`src/*.zig`（48 文件 / 135 项）、`lib/cordic.zig`、统一的 `build.zig` |
| `examples/compare/` | **三方对比用源码**：`cases.txt` + `c/sdcc/` + `c/keil/` |
| `tools/mcs2/` | 验收驱动、三方对比、周期估算（`cycles51.py`）、能力探针、真机脚本 |
| `docs/` | 项目文档（索引见 [`docs/README.md`](docs/README.md)） |

## 验证

- **仿真**：135 项用例，经 `sdas8051`+`sdld` 链成 `.ihx`，在 ucsim-51（8052 模式）里读回 xdata 判定。
- **真机**：129 项 / 42 组固件在 AI8051U-34K64（8 位模式）上跑通，含 Timer0 中断组；
  全自动烧录（写文件 → AiCube 发 `@STCISP#` → 固件软复位进 ISP → 收数比对）。
- **三方对照**：尺寸与周期随时用 `bench_compare.py` 重算；全量表见
  [对比-全部示例](docs/对比-全部示例-2026-11-02.md)。

## 已知限制

- **非尾递归不安全**：参数走静态 `PARM` 槽，内层调用会覆盖外层（尾递归已编成循环，安全）。
- **没有浮点**：交 STC 官方浮点库处理（C 侧），后端只保证定点/整数。
- `switch` 判定值限 **8 位**（256 种命令够用）；更大的命令字用「字节表 + 函数指针表」二级分派。
- `const` 表**只有一维**；多维 `const` 表暂不支持。
- `var` 的**初值不装载**（XRAM 掉电即失）；查表请用 `const`。
- **饱和算术**（`+|`/`-|`/`*|`）未实现，会明确报错。
- **ISR 里不要放带局部量的代码**（ISR 不走 epilogue）；逻辑放普通函数里再调用。
- 静态 RAM（DSEG）紧张：8051 只有 80 字节可直址 —— 见上表最后一列。
- 待办清单见 [`docs/待推进-2026-11-02.md`](docs/待推进-2026-11-02.md)。

## 与上游 Zig 的差异

| 路径 | 改动 |
| --- | --- |
| `src/codegen/mcs2.zig`、`src/codegen/mcs2/` | **新增**：AIR → MIR → 8051 汇编的后端 |
| `src/link/Asx.zig` | **新增**：ASxxxx 链接抽象（全局变量与 `const` 表的数据发射） |
| `lib/std/Target/mcs51.zig` 等 | mcs51/mcs251 目标定义 |
| `src/link/Coff.zig` | **放宽** COFF weak external 的 `value` 校验：规范要求 0，但自举时生成的 `compiler_rt.lib` 写入非零值，严格校验会让本编译器连自己的 build runner 都链不出来（`zig build` 因此不可用） |

宿主侧能力现在是通的：本仓库编出来的 `zig` 可以直接跑 `zig build`（见 `examples/mcs51`）。

## 文档

入口 [`docs/README.md`](docs/README.md)。最常看的三份：

| 文档 | 内容 |
| --- | --- |
| [M2 工作清单](docs/M2工作清单-2026-10-31.md) | 总清单：能力矩阵、P0/P1、坑台账、构建与真机命令 |
| [待推进-2026-11-02](docs/待推进-2026-11-02.md) | 下一步做什么（P0/P1/测试/结构/工程） |
| [对比-全部示例-2026-11-02](docs/对比-全部示例-2026-11-02.md) | 25 例三方对比（尺寸 + 周期），含口径与已知缺口 |

## 许可

与上游一致：MIT（见 [`LICENSE`](LICENSE)）。
