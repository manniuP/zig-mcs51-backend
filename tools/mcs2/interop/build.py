#!/usr/bin/env python3
"""C(SDCC) ↔ Zig(mcs2) 混编实验：同一条 .rel 链接链上的双向符号检查。

跑法（任意目录）：
    python zig-0.17/tools/mcs2/interop/build.py

它做三件事：
  1. Zig 侧 zig build-obj → .asm → sdas8051 → .rel；
  2. C 侧 sdcc -mmcs51 --model-large -c → .rel（与 examples/ai8051u/usb_cdc 同参数）；
  3. 用 **sdcc 当链接器**（这样 SDCC 的运行库/crt0 都可用）把两个 .rel 链成 .ihx，
     再从 .map/.sym 和 C 侧 .asm 里核对符号与调用约定。

结论口径：只验「能不能链上、ABI 对不对」；USB 枚举要看真机（板子没插时跑不了）。
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
MCS2 = HERE.parent
BUILD = HERE / "build"
WORKSPACE = MCS2.parents[2]
ZIG = WORKSPACE / "zig017" / "mcs2build" / "zig-out" / "bin" / "zig.exe"
SDCC_BIN = Path(os.environ.get("MCS_SDCC_BIN", WORKSPACE / "mcs251" / "tools" /
                               "sdcc-mcs251-windows-x64" / "sdcc-mcs251" / "bin"))


def run(cmd, **kw):
    print("+", " ".join(str(c) for c in cmd))
    r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True,
                       encoding="utf-8", errors="replace", **kw)
    if r.returncode != 0:
        print(r.stdout[-1500:])
        print(r.stderr[-1500:])
        raise SystemExit(f"失败（{r.returncode}）：{cmd[0]}")
    return r


def main() -> int:
    model = "small"
    if "--model-large" in sys.argv:
        model = "large"
    BUILD.mkdir(parents=True, exist_ok=True)
    print(f"== C 侧内存模型：--model-{model}"
          f"（large 会把 PARM 溢出区放 xdata，small 放 data —— 这是混编的关键差异）")
    for p, name in ((ZIG, "mcs2 编译器"), (SDCC_BIN / "sdcc.exe", "SDCC")):
        if not p.exists():
            raise SystemExit(f"缺 {name}：{p}")

    # 1) Zig 侧
    asm = BUILD / "cdc_zig.asm"
    run([ZIG, "build-obj", "-OReleaseSmall", "-target", "mcs51-freestanding",
         f"-femit-bin={asm}", HERE / "cdc_zig.zig"])
    zrel = BUILD / "cdc_zig.rel"
    run([SDCC_BIN / "sdas8051.exe", "-plosgffw", zrel, asm])

    # 2) C 侧（-S 顺带留一份汇编，用来核对调用约定）
    crel = BUILD / "cdc_hook.rel"
    run([SDCC_BIN / "sdcc.exe", "-mmcs51", f"--model-{model}", "-c",
         str(HERE / "cdc_hook.c"), "-o", str(crel)])
    casm = BUILD / "cdc_hook.asm"
    run([SDCC_BIN / "sdcc.exe", "-mmcs51", f"--model-{model}", "-S",
         str(HERE / "cdc_hook.c"), "-o", str(casm)])

    # 3) 用 sdcc 当链接器：把 .c 和 Zig 的 .rel 一起交给它，
    #    这样 SDCC 的 crt0 / HOME / PSEG / 运行库都会自动带上（纯 .rel 链接会缺它们）。
    ihx = BUILD / "cdc_mix.ihx"
    run([SDCC_BIN / "sdcc.exe", "-mmcs51", f"--model-{model}",
         str(HERE / "cdc_hook.c"), str(zrel), "-o", str(ihx)])

    sym = (BUILD / "cdc_mix.sym").read_text(errors="replace") if (BUILD / "cdc_mix.sym").exists() else ""
    text = casm.read_text(errors="replace")

    print("\n== 链接结果")
    for name in ("_zig_cdc_mix", "_zig_cdc_hash", "_main"):
        print(f"  {name:<18} {'OK' if name in sym else '缺失'}")

    print("\n== C 侧调用约定（cdc_hook.asm 摘录）")
    keep = []
    for line in text.splitlines():
        s = line.strip()
        if re.match(r"^(mov\s+dpl|mov\s+dph|mov\s+_zig_cdc|mov\s+\(_zig_cdc|lcall\s+_zig_cdc|mov\s+b,|mov\s+acc,)", s):
            keep.append("    " + s)
    print("\n".join(keep) if keep else "  （没找到）")

    zig_asm = asm.read_text(errors="replace")
    print("\n== Zig 侧入口（cdc_zig.asm 摘录）")
    for line in zig_asm.splitlines():
        s = line.strip()
        if s.startswith("mov _mcs_v") and ",0x8" in s:
            print("    " + s)
        if s in ("_zig_cdc_mix:", "_zig_cdc_hash:"):
            print("  " + s)
    print(f"\nOK: {ihx}（{ihx.stat().st_size} B）  映射：{BUILD / 'cdc_mix.map'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
