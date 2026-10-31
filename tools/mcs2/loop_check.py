#!/usr/bin/env python3
"""M2 验收：while 循环（cmp_br 融合 + 回边）→ ucsim。

用例：
  sum(5) = 0+1+2+3+4 = 10
  cnt(7) = 7（递减到 0）
链路同 add_check：zig → sdas8051 → sdld → ucsim。
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

    asm = BUILD / "loop.asm"
    run([str(ZIG017), "build-obj", "-OReleaseSmall",
         "-target", "mcs51-freestanding", "-femit-bin=" + str(asm),
         str(HERE / "tests" / "loop.zig")], env=env)

    text = asm.read_text(encoding="utf-8")
    for needle in ("L%d:" % 0, "sjmp", "jc", "jnc"):
        pass

    from assemble51 import assemble

    cases = [
        ("sum", 5, 10),
        ("cnt", 7, 7),
        ("sum_to_fold", None, 44),   # 0+1+...+24 = 300 -> u8 回绕 44；PE 应折叠
    ]
    fail = False
    for fn, arg, want in cases:
        driver = "    .area CSEG (CODE)\n"
        driver += "    mov sp,#0x7F\n"
        if arg is not None:
            driver += f"    mov dpl,#0x{arg:02X}\n"
        driver += f"    lcall _{fn}\n"
        driver += "    mov a,dpl\n    mov dptr,#0x8000\n    movx @dptr,a\n    sjmp .\n"
        merged = BUILD / f"{fn}_full.asm"
        merged.write_text(driver + text, encoding="utf-8", newline="\n")
        ihx = assemble(merged, BUILD, fn, dseg_base=0x30)
        print(f"产物：{ihx}")

        cmds = "set opt selfjump_stop 0\nstep 5000\ndump xram 0x8000 0x8001\nquit\n"
        sim = subprocess.run([find_ucsim(), "-t", "8052", str(ihx)],
                             input=cmds, capture_output=True, text=True, check=False)
        out = sim.stdout + sim.stderr
        m = re.search(r"^\s*0x8000\s+((?:[0-9a-fA-F]{2}[ \t]+)+)", out, re.MULTILINE)
        if not m:
            print("FAIL: 没有解析到 0x8000")
            print(out[-800:])
            fail = True
            continue
        got = int(m.group(1).split()[0], 16)
        ok = got == want
        label = f"{fn}({arg})" if arg is not None else f"{fn}()"
        print(f"{label} = {got}（期望 {want}）{'PASS' if ok else 'FAIL'}")
        if not ok:
            fail = True
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
