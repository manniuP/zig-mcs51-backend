#!/usr/bin/env python3
"""同源 C 的三方代码尺寸对比：mcs2 / SDCC 4.6 / Keil C51。

口径：
  - 同一份 C 源码（bench_c/），同一组函数；
  - 函数体字节数：mcs2 与 SDCC 走同一条 sdas8051+sdld 链，从 .lst 量「首条指令→RET」；
    Keil 读编译器 listing 里的 MODULE INFORMATION: CODE SIZE（每个文件只放一个函数）；
  - mcs2 侧复用 build/*.lst（先跑 python mcs2.py check <用例>）。

环境变量：
  MCS_SDCC_BIN   SDCC 的 bin 目录（默认工作区内置工具链）
  KEIL_BIN       Keil C51 的 BIN 目录；未设置时 Keil 列显示「未配置」
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BUILD = HERE / "build"
CB = HERE / "bench_c"
KEIL_DIR = BUILD / "keil"

sys.path.insert(0, str(HERE))
from assemble51 import assemble, toolchain_dir   # noqa: E402
from fnsize import fn_size                        # noqa: E402

# (标签, mcs2 的 .lst, 函数名, C 源)
CASES = [
    ("add",         "add.lst",         "add",         "add.c"),
    ("sum",         "sum.lst",         "sum",         "sum.c"),
    ("memrt",       "memrt.lst",       "memrt",       "memrt.c"),
    ("ringdemo",    "ringdemo.lst",    "ringdemo",    "ring.c"),
    ("sum_to_fold", "sum_to_fold.lst", "sum_to_fold", "fold.c"),
]


def sdcc_bin() -> Path:
    return toolchain_dir()


def sdcc_size(c_file: str, fn: str) -> int | None:
    sdcc = sdcc_bin() / "sdcc.exe"
    if not sdcc.exists():
        return None
    asm = BUILD / (c_file.replace(".c", "_sdcc.asm"))
    r = subprocess.run([str(sdcc), "-mmcs51", "--model-small", "-S",
                        "-o", str(asm), str(CB / c_file)],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode != 0:
        print(r.stdout, r.stderr)
        return None
    ihx = assemble(asm, BUILD, c_file.replace(".c", "_sdcc"))
    return fn_size(ihx.with_suffix(".lst"), fn)


def keil_size(c_file: str) -> int | None:
    keil_bin = os.environ.get("KEIL_BIN", "")
    c51 = Path(keil_bin) / "C51.EXE" if keil_bin else None
    if not c51 or not c51.exists():
        return None
    KEIL_DIR.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(CB / c_file, KEIL_DIR / c_file)
    lst = KEIL_DIR / c_file.replace(".c", ".lst")
    r = subprocess.run([str(c51), c_file, "SMALL", f"PRINT({lst.name})", "OPTIMIZE(8,SPEED)"],
                       cwd=KEIL_DIR, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    if r.returncode != 0 or not lst.exists():
        print(r.stdout[-500:], r.stderr[-300:])
        return None
    m = re.search(r"CODE SIZE\s*=\s*(\d+)", lst.read_text(errors="replace"))
    return int(m.group(1)) if m else None


def main() -> int:
    have_keil = bool(os.environ.get("KEIL_BIN"))
    print(f"{'用例':<13}{'mcs2':>8}{'SDCC 4.6':>10}{'Keil C51':>10}   备注")
    print("-" * 58)
    for tag, lst_name, fn, c_file in CASES:
        ours = fn_size(BUILD / lst_name, fn)
        sd = sdcc_size(c_file, fn)
        kl = keil_size(c_file) if have_keil else None
        note = "mcs2 走 PE 折叠（循环消失）" if tag == "sum_to_fold" else ""
        fmt = lambda v: f"{v} B" if v is not None else "—"
        print(f"{tag:<13}{fmt(ours):>8}{fmt(sd):>10}{fmt(kl):>10}   {note}")
    if not have_keil:
        print("\n（Keil 列未采集：设置 KEIL_BIN=<Keil\\C51\\BIN> 后重跑）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
