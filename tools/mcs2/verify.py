#!/usr/bin/env python3
"""mcs2 最小切片验证：MIR -> MCS51 汇编 -> ihx -> ucsim。

只验证 `src/codegen/mcs2/selftest.zig` 当前生成的无参数算术程序。
结果写入 xdata 0x8000，期望 0x07。

依赖：
  - 宿主编译器 zig（0.17）
  - SDCC 的 sdas8051/sdld（可用 MCS_SDCC_BIN 覆盖）
  - ucsim_51（可用 UCSIM51 覆盖；否则尝试 PATH 和 SDCC 默认安装）
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

from assemble51 import assemble

HERE = Path(__file__).resolve().parent
WORKSPACE = HERE.parents[2]
BUILD = HERE / "build"


def find_ucsim() -> Path:
    env = os.environ.get("UCSIM51")
    if env:
        return Path(env)
    found = shutil.which("ucsim_51")
    if found:
        return Path(found)
    candidate = Path(r"C:\Program Files (x86)\SDCC\bin\ucsim_51.exe")
    if candidate.exists():
        return candidate
    raise SystemExit("找不到 ucsim_51；请设置 UCSIM51")


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    print("+", " ".join(str(c) for c in cmd))
    return subprocess.run(cmd, check=True, capture_output=True, text=True,
                          encoding="utf-8", errors="replace", **kwargs)


def main() -> int:
    BUILD.mkdir(parents=True, exist_ok=True)
    ucsim = find_ucsim()

    # 1. MIR -> asm。selftest 用 stderr 输出汇编，避免依赖 0.17 的新 Io API。
    zig = shutil.which("zig")
    if not zig:
        raise SystemExit("找不到 zig；请把 0.17 加入 PATH")
    proc = run([zig, "run", str(HERE.parents[1] / "src" / "codegen" / "mcs2" / "selftest.zig")], cwd=HERE)
    asm = proc.stderr
    if "    .area CSEG (CODE)" not in asm:
        print(asm)
        raise SystemExit("MIR 发射器没有输出预期汇编")
    asm_path = BUILD / "out.asm"
    asm_path.write_text(asm, encoding="utf-8", newline="\n")

    # 2. asm -> rel -> ihx（统一走 assemble51，避免链接脚本两处漂移；
    #    STC 下载器直接接受 ihx，无需 packihx）
    ihx = assemble(asm_path, BUILD, "out")
    print(f"产物：{ihx}")

    # 3. ucsim 执行并 dump xram
    #    验收点：0x8000=0x07（3+4，旧验收）；
    #    0x8001=0x01、0x8002=0x00（倒数循环跑满 3 圈后归零）；
    #    0x8003=0x01（可穿线模式：br_ifnz→L1→sjmp L2 被穿线后路径不变）。
    cmds = "set opt selfjump_stop 0\nstep 400\ndump xram 0x8000 0x8004\nquit\n"
    sim = subprocess.run([str(ucsim), "-t", "8052", str(ihx)],
                         input=cmds, capture_output=True, text=True, check=False,
                         encoding="utf-8", errors="replace")
    out = sim.stdout + sim.stderr
    print(out)

    expected = {0x8000: 0x07, 0x8001: 0x01, 0x8002: 0x00, 0x8003: 0x01}
    # ucsim 的 dump 是一行多值：`0x8000   07 01 00 01 c8 ...`
    # （行尾是 ASCII 列，十六进制字段只有前 N 个）
    dumped: dict[int, int] = {}
    for line in out.splitlines():
        m = re.match(r"^\s*0x([0-9a-fA-F]{4})\s+((?:[0-9a-fA-F]{2}[ \t]+)+)", line)
        if not m:
            continue
        base = int(m.group(1), 16)
        for k, tok in enumerate(m.group(2).split()):
            dumped[base + k] = int(tok, 16)
    failed = False
    for addr, want in expected.items():
        if addr not in dumped:
            print(f"FAIL: 没有解析到 {addr:#06x} 的 xram 值")
            failed = True
            continue
        value = dumped[addr]
        if value != want:
            print(f"FAIL: {addr:#06x} = 0x{value:02X}，期望 0x{want:02X}")
            failed = True
        else:
            print(f"PASS: {addr:#06x} = 0x{value:02X}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
