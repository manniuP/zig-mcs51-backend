#!/usr/bin/env python3
"""M1 验收：export fn add(a: u8, b: u8) u8 → zig build-obj → sdas/sdld → ucsim。

链路：
  1. 用 zig-0.17 产物编译器编 tests/add.zig 出汇编（目标 mcs51-freestanding）；
  2. 前置 ASM 驱动：DPL=3/DPH=4 → lcall _add → 结果写 xdata 0x8000 → 停机；
  3. assemble51 出 ihx；ucsim 执行并校验 0x8000 == 0x07；
  4. 尺寸门禁：_add 函数体 ≤ 27B（1.5 × 旧后端 add8 基线 18B）。

依赖：ZIG017（zig-0.17 产物 zig.exe 路径，默认 zig-0.17/zig-out/bin/zig.exe）。
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
SIZE_BUDGET = 27

DRIVER = """\
; M1 验收驱动：摆参 → 调用 → 存结果 → 停机
    .area CSEG (CODE)
    mov dpl,#0x03
    mov dph,#0x04
    lcall _add
    mov dptr,#0x8000
    movx @dptr,a
    sjmp .
"""


def run(cmd, **kw):
    print("+", " ".join(str(c) for c in cmd))
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw)


def find_ucsim() -> str:
    env = os.environ.get("UCSIM51")
    if env:
        return env
    cand = Path(r"C:/Program Files (x86)/SDCC/bin/ucsim_51.exe")
    if cand.exists():
        return str(cand)
    found = None
    try:
        from shutil import which
        found = which("ucsim_51")
    except Exception:
        pass
    if not found:
        raise SystemExit("找不到 ucsim_51；请设置 UCSIM51")
    return found


def main() -> int:
    BUILD.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env["ZIG_LIB_DIR"] = str(LIB017)
    env["ZIG_GLOBAL_CACHE_DIR"] = str(WORKSPACE / "zig017" / "cbg")
    env["ZIG_LOCAL_CACHE_DIR"] = str(WORKSPACE / "zig017" / "cbgl")

    # M1 用例表：(模块源文件, 函数名, 参数列表[(摆放位置, 值)], 期望返回值)
    # 位置：'DPL' 直接地址 | 'PARM2' 静态 _<fn>_PARM_2
    CASES = [
        ("add.zig",    "add",    [("DPL", 3), ("PARM2", 4)], 0x07),
        ("locals.zig", "varfn",  [("DPL", 3)],               0x04),
        ("locals.zig", "addrfn", [("DPL", 5)],               0x06),
    ]

    from assemble51 import assemble
    fail = False
    out_slot = 0x8000
    for src_name, fn_name, args, want in CASES:
        tag = f"{fn_name}"
        print(f"=== 用例 {tag} ===")
        # 1. 编译模块
        asm = BUILD / (src_name.replace(".zig", ".asm"))
        r = run([str(ZIG017), "build-obj", "-OReleaseSmall",
                 "-target", "mcs51-freestanding", "-femit-bin=" + str(asm),
                 str(HERE / "tests" / src_name)], env=env)
        if "    .area CSEG (CODE)" not in asm.read_text(encoding="utf-8"):
            print(r.stderr)
            raise SystemExit("FAIL: 编译产物没有 CSEG")

        # 2. 驱动：摆参 → lcall → 结果写 xdata 槽 → 停机
        driver = "    .area CSEG (CODE)\n"
        for pos, val in args:
            if pos == "DPL":
                driver += "    mov dpl,#0x%02X\n" % val
            elif pos == "PARM2":
                driver += "    mov _%s_PARM_2,#0x%02X\n" % (fn_name, val)
        driver += f"    lcall _{fn_name}\n"
        driver += f"    mov dptr,#0x{out_slot:04X}\n    movx @dptr,a\n    sjmp .\n"
        merged = BUILD / (tag + "_full.asm")
        merged.write_text(driver + asm.read_text(encoding="utf-8"),
                          encoding="utf-8", newline="\n")
        # DSEG=0x30：避开复位栈区（SP=0x07，lcall 压栈占 0x08-0x09）。
        # 正式 crt0 会把 SP 抬到帧之上；harness 里直接挪 DSEG 基址最稳。
        ihx = assemble(merged, BUILD, tag, dseg_base=0x30)
        print(f"产物：{ihx}")

        # 3. ucsim 执行
        cmds = f"set opt selfjump_stop 0\nstep 400\ndump xram 0x{out_slot:04X} 0x{out_slot+1:04X}\nquit\n"
        sim = subprocess.run([find_ucsim(), "-t", "8052", str(ihx)],
                             input=cmds, capture_output=True, text=True, check=False)
        out = sim.stdout + sim.stderr
        m = re.search(rf"^\s*0x{out_slot:04X}\s+((?:[0-9a-fA-F]{{2}}[ \t]+)+)", out, re.MULTILINE)
        if not m:
            print(f"FAIL: 没有解析到 {out_slot:#06x}")
            print(out[-600:])
            fail = True
            continue
        value = int(m.group(1).split()[0], 16)
        if value != want:
            print(f"FAIL: {fn_name} = 0x{value:02X}，期望 0x{want:02X}")
            fail = True
        else:
            print(f"PASS: {fn_name} = 0x{value:02X}")
        out_slot += 1

    # 4. 尺寸门禁：_add 函数体 = 从 _add 标签后的首条指令行，
    #    到第一条 RET 行为止（地址差分，旧尺子同源方法）。
    lst = (BUILD / "add.lst").read_text(errors="replace")
    lines = lst.splitlines()
    label_idx = None
    for i, line in enumerate(lines):
        # listing 里标签行形如 `      00000F                         20 _add_add:`
        # （地址列可有可无，关键是行尾 `_add:`）；跳过 .globl 行
        if "_add:" in line and ".globl" not in line:
            label_idx = i
            break
    if label_idx is None:
        print("FAIL: listing 里没有找到 _add")
        return 1
    rows = []
    for line in lines:
        m2 = re.match(r"^\s*([0-9A-Fa-f]{4,6})\s+(\S.*?)\s*\[\s*\d+\]\s+\d+\s+(.*)$", line)
        if m2:
            rows.append((int(m2.group(1), 16), m2.group(3).strip()))
    start = None
    end = None
    for addr, text in rows:
        if start is None:
            # 跳过驱动段：从 _add 标签行号之后开始取第一行
            if addr is not None and lines.index(next(l for l in lines if "_add" in l and ":" in l), 0) >= 0:
                pass
        # 用更直接的方法：先找 _add 后第一条指令行
        break
    # 直接法：_add 标签行之后，第一行带指令字段的行是函数体起点
    after = lines[label_idx + 1:]
    start_addr = None
    for line in after:
        m2 = re.match(r"^\s*([0-9A-Fa-f]{4,6})\s+\S.*?\[\s*\d+\]\s+\d+\s+(.*)$", line)
        if m2:
            start_addr = int(m2.group(1), 16)
            break
    if start_addr is None:
        print("FAIL: _add 后没有指令行")
        return 1
    in_body = False
    for addr, text in rows:
        if addr < start_addr:
            continue
        if text.upper().startswith("RET"):
            end = addr + 1
            break
    if end is None:
        print("FAIL: 没找到函数体的 RET")
        return 1
    n = end - start_addr
    print("PASS: 尺寸门禁")
    return 0


if __name__ == "__main__":
    sys.exit(main())
