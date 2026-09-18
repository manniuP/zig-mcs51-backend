# 15 汇编瘦身工具 `mcs_opt.py`（构建层后处理，无需重编编译器）

> 相关：[06-常见问题与限制](06-常见问题与限制.md) 的“代码尺寸”一节、
> [02-工程结构与构建流程](02-工程结构与构建流程.md) 的三段式流程、
> `tools/mcs_opt.py` 头注释（规则细节）。

## 1. 为什么做这个工具

- MCS 后端**为每个内联调用点各生成一份代码**，且偏好「先把值写进 SPX 帧槽、再读回来」；
  `inc/dec spx` 又只能以 `#1/#2/#4` 为步长，prologue/epilogue 会展开成一长串。
- `sdld` **不回收未用段**，代码容易顶满 64KB Flash（AiCube 报“超出文件大小、溢出移 EEPROM”）。
- 重编 `zig.exe`（自举）很慢，所以把「瘦身」做成**构建层后处理**：只改 `.asm` 文本，
  **不改后端、不重编编译器**。

## 2. 位置与接入

- 工具：`tools/mcs_opt.py`（Python，无第三方依赖）。
- 接入：`xmake.lua` 各 Zig 目标在 `fix_mcs_labels.py` **之后**、`sdas*` **之前**调用它。
  流水线变为：

  ```
  zig build-obj ─▶ .asm ─▶ fix_mcs_labels.py ─▶ mcs_opt.py ─▶ sdas* ─▶ sdld/sdcc ─▶ .ihx
  ```

  > 注意：xmake 的 `on_build` 沙箱**看不到脚本级函数**，所以那段调用只能在每个目标里
  > 内联展开，不能抽成 helper。

## 3. 规则（R1~R5）

均在**基本块内**、不跨标签/分支/调用；未知指令一律当“清空状态”的屏障；重复跑到不动点。

| 规则 | 说明 | 示例 |
| --- | --- | --- |
| **R1** | 合并连续同向 `inc/dec spx,#1\|2\|4` → 单条 `add/sub spx,#imm16` | `inc spx,#0x04`×17 → `add spx,#0x0044` |
| **R2** | 直块内值编号，删冗余 `mov` | `mov a,@spx-4 ; mov r0,a ; mov a,@spx-4` → 第三条删 |
| **R3** | `mov a,X ; mov Y,a`（a 随后被覆盖）→ `mov Y,X` | `mov a,@spx-8 ; mov r0,a` → `mov r0,@spx-8` |
| **R4** | A 为编译期常量时直接写目标寄存器 | `mov a,#0x12 ; mov dpl,a` → `mov dpl,#0x12` |
| **R5a** | `ejmp L` 紧跟 `L:`（跳到下一行）= 空操作 → 删跳转 | 后端空块/循环常生成 |
| **R5b** | 无条件转移（`ejmp/ljmp/sjmp/ajmp/jmp/ret/reti/eret`）之后、下一标签之前的不可达指令 → 删 | 函数尾多余的 `eret` 等 |

`mov Y,X` 的合法性（R3）按 sdas251 实测表判断（见 `_can_mov`）：如 `@spx` 只能进
`a`/`rN`，不能进 `dpl/dph/b`；`mov @spx,#imm` 不存在等。

## 4. 用法与自测

```powershell
python tools\mcs_opt.py <file.asm>            # 就地改写（构建已自动调用）
python tools\mcs_opt.py <in.asm> -o <out.asm> # 输出到别处
python tools\mcs_opt.py <file.asm> --stats    # 各规则命中次数 + 指令数变化
python tools\mcs_opt.py --self-test           # 内置回归用例（R1~R5，8 个）
python tools\mcs_opt.py <file.asm> --no-r5    # 关闭某条规则（r1..r5）
```

## 5. 各例程实测（CSEG 字节）

口径：**raw = 仅过 `fix_mcs_labels`**；**opt = 再过 `mcs_opt`**。含少量 C 部分
（`blink`/`ptrtest` 的 C 代码不经本工具）。

| 例程 | 架构 | raw | opt | 降幅 |
| --- | --- | ---: | ---: | ---: |
| `zigled` | mcs251 | 337 | 286 | -15.1% |
| `zigasm` | mcs251 | 311 | 259 | -16.7% |
| `zigirq`（isr） | mcs251 | 49 | 48 | -2.0% |
| `blink` | mcs251 | 303 | 256 | -15.5% |
| `ptrtest` | mcs251 | 2095 | 1838 | -12.3% |
| `zigbuzz` | mcs251 | 13825 | 11348 | -17.9% |
| `ziglog` | mcs251 | 12563 | 10360 | -17.5% |
| **`zigmem`** | mcs251 | **10268** | **6155** | **-40.1%** |
| `blink` | **mcs51** | 228 | 220 | -3.5% |
| `simtest` | **mcs51** | 761 | 753 | -1.0% |

## 6. 结论

- **mcs251 普遍 12~18%**；循环/表格密集的 `zigmem` 高达 **-40%**——后端在空块/循环处
  大量生成 `ejmp L; L:`，R5 一次删掉一大片。
- **mcs51 很小（-1~-3.5%）**：只有 `blink`/`simtest` 两个很小的 Zig 模块，且 8 位后端用
  **静态 idata 帧**（无 SPX 帧），R1/R3/R4 基本不触发，仅 R2/R5 生效。
- 本工具是「不重编编译器也能瘦身」的**过渡手段**；根治仍是后端输出更紧凑
  （减少中间帧槽/冗余搬运，见交接 §5.10③）。

## 7. 验证

- `python tools/mcs_opt.py --self-test` → **8/8**。
- mcs51 软件仿真：`simtest`（WSL `ucsim_51`）XRAM `0x8000 = aa 00 02 04 08 10 20 40 80 01 …`，
  行为与优化前一致。
- **mcs251 真机（AI8051U）**：
  - 优化后 `ziglog`：UART1 六帧齐全 `boot/count/xy/cvar/msg/g16`（g16==count，msg "hello"）；
  - 优化后 `zigmem`（R5 削减最多）：UART1 周期输出 `a1 ok b2 ok c3 ok d4 ok`（四空间正确）。

## 8. 后续（兜底方向）

- 真「从未被引用的函数」在当前示例中是 **0**：Zig 只发射被引用到的函数，故工具暂不做
  函数级 DCE（仅 C+Zig 混编且需显式 roots 时才有意义）。
- **代码再也压不下去时的兜底**：把**常量数据**放 EEPROM、用 `MOV` 读
  （`*(unsigned char far *)(0xff0000|addr)`，走代码空间，快于 IAP）；函数放 EEPROM 直接调用
  **不支持**，只能走「用户系统区 / 做自己的 ISP（OTA）」自举跳转。注意 AI8051U-34K64 的
  EEPROM **与程序区共用同一块 64K Flash**，不能靠它扩容代码总量。
