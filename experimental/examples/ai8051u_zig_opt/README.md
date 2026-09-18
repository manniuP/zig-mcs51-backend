# ai8051u_zig_opt — 放置标签 + 优化等级（O0–O3/Ofast/Os，GCC 对齐）+ UART 实机核验

演示「**Zig 标签 → IR 提示注释 → 放置 + 体积/速度优化**」，并给出**固定 UART 输出**便于真机核对。

## 两个维度

**放置标签**（`linksection` 字符串，可空格组合）：

| 标签 | 空间 | 寻址 |
| --- | --- | --- |
| `data` | `DSEG` | 直址 `mov a,dir8`（最快） |
| `idata` | `ISEG` | `@r0` |
| `edata` | `EDATA` | `movx @dptr`（251 片上） |
| `xdata` | `XSEG` | `movx @dpx`（24 位） |
| `exdata` | `EXDATA` | 片外（需外接，暂未验证） |
| 不写 | — | 编译器自决（`≤2B`→data，否则默认） |

**优化等级**（**与 GCC 对齐**，可空格组合；不写=默认 O3）：

| 等级 | 取向 |
| --- | --- |
| `O0`–`O3` | 优化力度（偏速度） |
| `Ofast` | 最快（最占空间） |
| `Os` | 偏体积（最省；函数进 `COLD` 区） |

> 当前后端只有「体积/速度」一个开关：`Os` 开条件融合（+`COLD` 区），其余等级暂同；后续再加旋钮。

> `lib/mcs251.zig` 导出常量：`m.data`/`m.idata`/`m.edata`/`m.xdata`/`m.exdata`、
> `m.O0`…`m.O3`/`m.Ofast`/`m.Os`；组合写法 `linksection(m.xdata ++ " " ++ m.Os)`。
> 后端把标签以 `; @tag func|sym <name> <place><level>` 注释传给中间层，`tools/mcs_ir.py` 消费后删除。
> **数据压缩/解压由用户自行实现**（工具链不做）。

## 构建

```powershell
xmake f --mcs_arch=mcs251
xmake build zigopt        # 产物 opt.ihx
```

## 预期输出（UART1 P3.1 @9600，每轮相同）

```
opt
opt 11223344 060a
opt 11223344 060a
...
```

- `11 22 33 44`：`v_data`/`v_idata`/`v_edata`/`v_auto` 读回（证明各层读写正确）；
- `06`：`acc_fast(4)`（`Ofast`）；`0a`：`acc_small(5)`（`Os`）。

## 反汇编核对（`opt.lst` / `opt.map`）

- `_v_data`→`DSEG`；`_v_idata`→`ISEG`；`_v_edata`→`EDATA`（`mov dptr,#_v_edata; movx a,@dptr`）；
- `acc_fast`（`Ofast`）在 `CSEG`；`acc_small`（`Os`）在 `COLD` 区。

QEMU 无板：`wsl -e bash tools/qemu_mcs_run.sh examples/ai8051u_zig_opt/opt.ihx`。

