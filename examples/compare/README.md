# 三方对比用的源码（mcs2 / SDCC / Keil）

这里放**同一段语义**的三份实现，用来量尺寸：

```
examples/compare/
  cases.txt          # 用例表：tag | mcs2 的 .lst | mcs2 函数标签 | C 函数名 | 备注
  c/sdcc/<tag>.c     # SDCC 方言（__xdata、static const）
  c/keil/<tag>.c     # Keil 方言（xdata、static const code）
  out/               # 跑对比时的中间产物（gitignore）
```

Zig 侧的源码在 `examples/mcs51/src/`，通过 `cases.txt` 里的 `.lst` 名字对应过去。

## 跑法

```bash
python tools/mcs2/mcs2.py check          # 先刷一遍 .lst（对比读的是它）
KEIL_BIN=<Keil>\C51\BIN python tools/mcs2/bench_compare.py
```

不设 `KEIL_BIN` 时 Keil 列显示 `—`（脚本会先尝试 `%LOCALAPPDATA%\Keil_v5\C51\BIN`）。

## 口径

- **函数体字节数** = 首条指令 → `RET`（SDCC 的库尾调用没有 RET，退化成到 `ljmp` 结束）
- `mcs2 DSEG` = 该函数 `.ds 1` 的槽数（每函数一块静态槽）
- `Keil DATA` = listing 里 `DATA SIZE`
- **注意内联 vs 库函数**：SDCC/Keil 把 32 位乘除、有符号除下沉到库（站点只几字节），
  mcs2 现在还每处内联整段模板。所以 u16/u32 那几行要看"连库一起"的总量才公平。
