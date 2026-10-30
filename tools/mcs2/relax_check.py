#!/usr/bin/env python3
"""M2.3 验收：大循环体（>128 字节）的回边松弛。

- 回边距离超过 sjmp 的 ±128 → 必须保持 ljmp，且 sdas 不得报 out of range；
- 执行 big(3) = 90（每轮加 30）。
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
WORKSPACE = HERE.parents[2]
BUILD = HERE / "build"

ZIG017 = Path(os.environ.get(
    "ZIG017", WORKSPACE / "zig017" / "mcs2build" / "zig-out" / "bin" / "zig.exe"))
LIB017 = WORKSPACE / "zig-0.17" / "lib"


def run(cmd, **kw):
    print("+", " ".join(str(c) for c in cmd))
    return subprocess.run(cmd, check=True, capture_output=True, text=True,
                          encoding="utf-8", errors="replace", **kw)


def find_ucsim() -> str:
    env = os.environ.get("UCSIM51")
    if env:
        return env
    cand = Path(r"C:/Program Files (x86)/SDCC/bin/ucsim_51.exe")
    if cand.exists():
        return str(cand)
    raise SystemExit("找不到 ucsim_51；请设置 UCSIM51")


def main() -> int:
    BUILD.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env["ZIG_LIB_DIR"] = str(LIB017)
    env["ZIG_GLOBAL_CACHE_DIR"] = str(WORKSPACE / "zig017" / "cbg")
    env["ZIG_LOCAL_CACHE_DIR"] = str(WORKSPACE / "zig017" / "cbgl")

    asm = BUILD / "bigloop.asm"
    run([str(ZIG017), "build-obj", "-OReleaseSmall",
         "-target", "mcs51-freestanding", "-femit-bin=" + str(asm),
         str(HERE / "tests" / "bigloop.zig")], env=env)

    text = asm.read_text(encoding="utf-8")
    has_ljmp = "ljmp" in text

    from assemble51 import assemble

    driver = "    .area CSEG (CODE)\n    mov sp,#0x7F\n    mov dpl,#0x03\n"
    driver += "    lcall _big\n    mov a,dpl\n    mov dptr,#0x8000\n    movx @dptr,a\n    sjmp .\n"
    merged = BUILD / "bigloop_full.asm"
    merged.write_text(driver + text, encoding="utf-8", newline="\n")
    ihx = assemble(merged, BUILD, "bigloop", dseg_base=0x08)
    print(f"产物：{ihx}（回边含 ljmp: {has_ljmp}）")

    cmds = "set opt selfjump_stop 0\nstep 20000\ndump xram 0x8000 0x8001\nquit\n"
    sim = subprocess.run([find_ucsim(), "-t", "8052", str(ihx)],
                         input=cmds, capture_output=True, text=True, check=False,
                         encoding="utf-8", errors="replace")
    out = sim.stdout + sim.stderr
    m = re.search(r"^\s*0x8000\s+((?:[0-9a-fA-F]{2}[ \t]+)+)", out, re.MULTILINE)
    if not m:
        print("FAIL: 没有解析到 0x8000")
        print(out[-600:])
        return 1
    got = int(m.group(1).split()[0], 16)
    ok = got == 90
    print(f"big(3) = {got}（期望 90）{'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
