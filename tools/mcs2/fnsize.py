#!/usr/bin/env python3
"""从 sdas8051 的 .lst 里量函数体字节数（首条指令 → 第一条 RET 之后）。"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROW = re.compile(r"^\s*([0-9A-Fa-f]{4,6})\s+\S.*?\[\s*\d+\]\s+\d+\s+(.*)$")


def fn_size(lst: Path, name: str) -> int | None:
    """量函数体字节数。

    先找 `_loop_<name>:`（mcs2 的函数体标签），否则找 `_<name>:`；
    mcs2 的公开符号是 `<name>: ljmp _loop_<name>` 的三字节别名，不能当函数体量。
    """
    lines = lst.read_text(errors="replace").splitlines()
    idx = None
    for want in (f"_loop_{name}:", f"_{name}:"):
        for i, line in enumerate(lines):
            if want in line and ".globl" not in line:
                idx = i
                break
        if idx is not None:
            break
    if idx is None:
        return None
    rows = []
    for line in lines[idx + 1:]:
        m = ROW.match(line)
        if m:
            rows.append((int(m.group(1), 16), m.group(2).strip()))
    if not rows:
        return None
    start = rows[0][0]
    end = next((a + 1 for a, t in rows if t.upper().startswith("RET")), None)
    return None if end is None else end - start


if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit("用法: fnsize.py <file.lst> <fn> [fn...]")
    lst = Path(sys.argv[1])
    for name in sys.argv[2:]:
        n = fn_size(lst, name)
        print(f"{name}: {n} B" if n is not None else f"{name}: 解析失败")
