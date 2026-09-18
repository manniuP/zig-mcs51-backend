# 21 - 指令周期参考与 bench 验证

> 主题：把 **STC AI8051U 手册附录A.1.3 的指令周期表**落成可用的参考表 + 工具
> （`tools/mcs_cycles.py`），并用它**验证真机 `zigbench` 的实测周期**、**量化优化空间**。
> 数据来源：`AI8051U` 数据手册 **附录A.1.3 指令表（功能排序）**（另见 A.1.2 标记、A.3 流水线中断）。

## 1. 来源与计算公式

手册 A.1.3 给出每条指令的 `编码 / 字节 / 时钟数`，表中数值是 **`WTST=0`** 时的系统时钟数；
实际总时间（手册表头原文）：

```
指令时钟数 = 时钟数 + nrPRGACS*WTST                 （nrPRGACS = 0 或 1；取指等待）
指令时钟数 = 时钟数 + nrPRGACS*WTST + nrXDMACS*CKCON （访问 XDM 存储器时）
```

- `WTST`（0xE9）程序存储器等待周期；`CKCON[2:0]` XDM 访问等待，`nrXDMACS`=1 或 2。
- `A.1.4 指令表（机器码排序）`只有操作码↔助记符，**无周期**；周期只在 A.1.3。
- 经典 8 位核看各自手册（如 `STC89C52RC-RD+` 8.2 指令表，单位是机器周期）。

## 2. 参考表（本后端会生成的形态）

操作数类别：`a` 累加器、`rn` R0–R7、`dreg` 寄存器（`dptr/dpxl/spx/dpx`）、`atr` `@Ri`、
`atdreg` DR 间接（`@spx±dis` / `@dpx`）、`imm` `#data`、`dir` 直接地址/SFR/符号、`bit` 位。

| 形态 | 字节 | 时钟 | 备注 |
| --- | --- | --- | --- |
| MOV A,#data / MOV A,dir8 | 2 | 1 | 含 SFR、`.data` 全局 |
| MOV A,Rn | 1 | 2 | |
| MOV A,@Ri | 1 | 2 | idata |
| MOV Rm,@DRk+dis（`@spx±d`/`@dpx`） | 4 | 1* | `*` 见 §4：XDM 访问另加 CKCON |
| MOV Rn,A / MOV Rn,dir8 / MOV Rn,#data | 1/2/2 | 2/1/1 | |
| MOV dir8,A / dir8,Rn / dir8,#data / dir8,dir8 | 2/2/3/3 | 1 | SFR 写 |
| MOV @Ri,A / @Ri,#data | 1/2 | 2 | |
| MOV @DRk+dis,Rm | 4 | 1* | 帧槽写 |
| MOV DPTR,#data16 / DRk,DRk | 3/2 | 1 | |
| MOVX A,@DPTR / @DPTR,A | 1 | 3 / 2 | 外部（edata） |
| MOVX A,@Ri / @Ri,A | 1 | 3 / 2 | |
| MOVC A,@A+DPTR / @A+PC | 1 | 4 / 3 | 常量表 |
| PUSH/POP dir8 | 2 | 1 | |
| ADD/ADDC/SUBB/ANL/ORL/XRL A,Rn | 1 | 2 | |
| ADD/ADDC/SUBB/ANL/ORL/XRL A,#data 或 A,dir8 | 2 | 1 | |
| ADD/SUB/ANL/ORL/XRL dir8,#data | 3 | 1 | SFR 读改写 |
| INC/DEC A | 1 | 1 | |
| INC/DEC Rn / @Ri | 1 | 2 | |
| INC/DEC dir8 | 2 | 1 | |
| INC/DEC/Rm,op2（`add/sub/inc/dec spx,#imm`） | 注 | 1 | op2 形态，手册「详见指令详解」，此处取 1 |
| MUL A,B / Rm,Rm / WRj,WRj | 1/2/2 | 1 | |
| DIV A,B / Rm,Rm | 1 | 6 | |
| DIV WRj,WRj | 1 | 10 | |
| DA A | 1 | 3 | |
| CLR/CPL A、RL/RLC/RR/RRC A、SWAP A | 1 | 1 | |
| CLR/SETB/CPL C 或 bit | 1/2 | 1 | |
| ANL/ORL C,bit、MOV C,bit / bit,C | 2 | 1 | |
| NOP | 1 | 1 | |
| ACALL/LCALL/ECALL | 2/3/4 | 3 | |
| RET/ERET/RETI | 1 | 3 | |
| AJMP/LJMP/EJMP/SJMP/JMP @A+DPTR | 2/3/4/2/1 | 3 | |
| JZ/JNZ/JC/JNC/JB/JNB/JBC（及有符号/无符号条件跳） | 2–3 | **1/3** | 不跳 / 跳 |
| CJNE A,dir8 / A,#data / Rn,#data / @Ri,#data | 3 | 2/3、1/3、3/4、3/4 | |
| DJNZ Rn / dir8 | 2/3 | 3/4 / 2/3 | |

> 完整 182 行见手册附录A.1.3；本表只列后端 emit 的形态（`--dump` 可打印）。
> `*` 标记：DR 间接访问 XDM 时按公式另加 `nrXDMACS*CKCON`（§4 xdata 实测约 +2）。

## 3. 工具 `tools/mcs_cycles.py`

```powershell
python tools\mcs_cycles.py --dump                      # 打印参考表
python tools\mcs_cycles.py --summary  <x.asm>          # 按函数汇总静态周期/指令数/未识别
python tools\mcs_cycles.py --annotate <x.asm>          # 逐条标注（1/3 条件跳转）
python tools\mcs_cycles.py --range 1255 1291 --taken <x.asm>   # 指定行区间汇总（分支按跳计）
```

`--summary` 会列出**未识别指令**，补齐 `FORM` 即可扩展（覆盖后端新形态）。周期是**静态**计数；
循环体总周期 = 各基本块之和，见 §4 的算法。
已对 `examples/**/*.asm`（含 SDCC 编出的 C 形态 `mov dir,@Ri`、`xch`、`movz` 等）跑通，0 未识别。

## 4. 真机 bench 验证（AI8051U-34K64 @40MHz）

`examples/ai8051u_zig_bench` 用 Timer0 1T 测「N 次操作」的周期。各测量函数结构相同：
`prologue + ecall t0Now + 循环(NREAD=500) + ecall t0Now + sub + epilogue`，
其中固定的**调用开销 OVH**（两次 `t0Now`、prologue/epilogue、`sub` 等）由 nop 基线标定。

循环体每轮 = **条件块**(14，含 `jnz` 按跳) + **体** + **回跳 ejmp**(3)。逐块用周期表求和：

| 循环 | 条件块 | 体（关键读数） | 回跳 | 每轮 | ×500+OVH | 实测 |
| --- | --- | --- | --- | --- | --- | --- |
| nop | 14 | 17（空循环，仅 i++） | 3 | 34 | 17157 | **0x4305**=17157 |
| data | 14 | 26（内含 `mov a,_v_data`=1） | 3 | 43 | 21657 | **0x5499**=21657 |
| idata | 14 | 28（`mov r0,#sym`=1 + `mov a,@r0`=2） | 3 | 45 | 22657 | **0x5881**=22657 |
| edata | 14 | 29（`mov dptr,#sym`=1 + `movx a,@dptr`=3） | 3 | 46 | 23157 | **0x5a75**=23157 |
| xdata | 14 | 30（`dptr`=1 + `dpxl`=1 + `@dpx`=3） | 3 | 47 | 23657 | **0x5c69**=23657 |

**结论**：`OVH = 实测 − 每轮×500 = 157`，五组**逐项精确吻合**
（`21657−43×500 = 17157−34×500 = 157` 等）。这同时：

1. 验证了周期表 + 后端的静态周期模型；
2. 反推出 **`@dpx`（XDM，24 位间接）实为 3 周期**（表按 `MOV Rm,@DRk+dis`=1，
   XDM 访问另加 `nrXDMACS*CKCON`≈2，正是手册公式那一项）；edata 的 `MOVX @DPTR`=3（外部，无此项）。
3. 实测扣 `nop` 后每次读 ≈ **9 / 11 / 12 / 13** 周期（data/idata/edata/xdata），与体差一致。

**函数调用（exec）**：`accFast`/`accSmall` 同体、仅等级标签不同。
模型：外循环每轮 47 + 被调函数；`accFast`(Os) = prologue 6 + 4×(cond10+body18) + 末判 11 + epilogue 6 = **135**，
`accSmall`(Ofast) = **138**（多一条 `ejmp` = 3）。于是
`100×(47+135)+157 = 18357 = 0x47b5`（实测 Os）、`100×(47+138)+157 = 18657 = 0x48e1`（实测 Ofast），
**逐周期吻合**——也说明上一轮「互换标签」后周期随标签走。

## 5. 优化计算

以 `data` 读循环为例（每轮 43）：

| 组成 | 周期 | 说明 |
| --- | --- | --- |
| 条件块（`i<N` 比较） | 14 | 拷 16 位 i 到两个临时槽(4) + `clr/subb/subb/clr/addc`(6) + `jnz`(3) + 分支落空 |
| 循环回跳 `ejmp` | 3 | |
| 体（读+加+写回+`i++`） | 26 | 其中真正必要：读 1、加 2、`i++`≈2 |
| **合计** | **43** | |

**优化项与收益**（500 轮/次，×500 的周期）：

1. **下行计数 + `DJNZ`**：把「条件块 14 + 回跳 3 = 17」换成 `djnz rn,L`（3–4）。
   仅此一项每轮省 **~13**，`data` 43→30（**−30%**，每次省 ~6500 周期）。
   > **已实现并真机验证**（构建层 `tools/mcs_loop.py`，`MCS_LOOP=1`）：连同 `i++` 帧搬运、读体折叠
   > 一起去掉，`data` 每轮 **43→7**；`zigbench` 实测四种读 **−68%~−83%**（含调用循环用 DSEG 计数）。
   > 详见 [22-循环下行计数DJNZ](22-循环下行计数DJNZ.md)。
2. **寄存器分配**（`acc`/`i` 常驻寄存器、地址提升出循环）：体 26→≈4，每轮 43→≈8–9
   （**−80%**）。属后端工程（需分配器），构建层 peephole 无法完成。
3. **块内拷贝传播**：条件块「拷 i 到 2 个临时槽」4 条 `mov`，可望被值级 CSE/合并省去（≤4/轮）。
4. **常量/地址提升**：`edata/xdata` 每轮重算 `dptr(+dpxl)`，可外提（省 1–2/轮）。
5. **等级标签**：`Ofast` 比 `Os` 多 3 周期来自**布局多出的 `ejmp`**（非真优化差异）——
   后端可加短跳松弛消除；这正是「等级细化」要补的旋钮（见 `docs/17`）。

> 结论：当前收益最大的不是「哪条指令选得更快」，而是**消除帧搬运与循环管理开销**
> （寄存器分配 / 循环惯用式）。周期表 + 本工具可对这些改动做**改前改后**的逐项预算。
