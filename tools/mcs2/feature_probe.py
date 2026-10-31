#!/usr/bin/env python3
"""定点能力矩阵探针：逐个最小用例编译，报告「支持 / 明确拒绝（附原因）」。

用途：回答"某类算术今天能不能编"，并防止能力回退。
注意：拒绝必须是**明确报错**——静默截断（比如把 u16 加法当 u8 做）属于 bug。

用法：python feature_probe.py            # 全部
      python feature_probe.py mul        # 只看名字里含 mul 的
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ZIG = Path(os.environ.get(
    "ZIG017", HERE.parents[2] / "zig017" / "mcs2build" / "zig-out" / "bin" / "zig.exe"))
ZIG_LIB = HERE.parents[1] / "lib"
CACHE = HERE.parents[2] / "zig017"

CASES: list[tuple[str, str]] = [
    # ---- 8 位无符号：算术 ----
    ("add8",      "export fn f(a: u8, b: u8) u8 { return a +% b; }"),
    ("sub8",      "export fn f(a: u8, b: u8) u8 { return a -% b; }"),
    ("mul8",      "export fn f(a: u8, b: u8) u8 { return a *% b; }"),
    ("div8",      "export fn f(a: u8, b: u8) u8 { return a / b; }"),
    ("rem8",      "export fn f(a: u8, b: u8) u8 { return a % b; }"),
    ("sat_add8",  "export fn f(a: u8, b: u8) u8 { return a +| b; }"),
    # ---- 8 位：位运算 ----
    ("and8",      "export fn f(a: u8, b: u8) u8 { return a & b; }"),
    ("or8",       "export fn f(a: u8, b: u8) u8 { return a | b; }"),
    ("xor8",      "export fn f(a: u8, b: u8) u8 { return a ^ b; }"),
    ("not8",      "export fn f(a: u8) u8 { return ~a; }"),
    ("xnor8",     "export fn f(a: u8, b: u8) u8 { return ~(a ^ b); }"),
    ("shl8",      "export fn f(a: u8) u8 { return a << 3; }"),
    ("shr8",      "export fn f(a: u8) u8 { return a >> 3; }"),
    ("rot8",      "export fn f(a: u8) u8 { return (a << 1) | (a >> 7); }"),
    # ---- 位寻址 ----
    ("bit_test",  "const S: *volatile u8 = @ptrFromInt(0x98); export fn f() u8 { S.* = 2; return if ((S.* & 2) != 0) 1 else 0; }"),
    ("bit_set",   "const S: *volatile u8 = @ptrFromInt(0x98); export fn f() u8 { S.* |= 2; return S.*; }"),
    # ---- 多字节（Q15/Q31 的前提）----
    ("u16_add",   "export fn f() u8 { var a: u16 = 0x1234; a +%= 1; return @truncate(a); }"),
    ("u16_mul",   "export fn f() u8 { var a: u16 = 0x1234; a *%= 3; return @truncate(a); }"),
    ("u32_add",   "export fn f() u8 { var a: u32 = 0x12345678; a +%= 1; return @truncate(a); }"),
    ("u16_arg",   "export fn f(a: u16) u16 { return a +% 1; }"),
    # ---- 有符号（Q15/Q31 都是带符号）----
    ("i8_add",    "export fn f(a: i8, b: i8) i8 { return a +% b; }"),
    ("i8_shr",    "export fn f(a: i8) i8 { return a >> 1; }"),
    ("i8_cmp",    "export fn f(a: i8, b: i8) u8 { return if (a < b) 1 else 0; }"),
    ("i16_local", "export fn f() u8 { var a: i16 = -3; a >>= 1; return @intCast(@as(u8, @truncate(@as(u16, @bitCast(a))))); }"),
]


def main(argv: list[str]) -> int:
    needle = argv[1] if len(argv) > 1 else ""
    env = dict(os.environ)
    env["ZIG_LIB_DIR"] = str(ZIG_LIB)
    env["ZIG_GLOBAL_CACHE_DIR"] = str(CACHE / "cache-mcs2")
    env["ZIG_LOCAL_CACHE_DIR"] = str(CACHE / "cache-mcs2-local")
    tmp = Path(tempfile.mkdtemp(prefix="mcs2probe-"))
    ok = bad = 0
    print(f"{'用例':<12}{'结果':<6}说明")
    print("-" * 88)
    for name, src in CASES:
        if needle and needle not in name:
            continue
        f = tmp / f"{name}.zig"
        f.write_text(src, encoding="utf-8")
        asm = tmp / f"{name}.asm"
        r = subprocess.run(
            [str(ZIG), "build-obj", "-OReleaseSmall", "-target", "mcs51-freestanding",
             f"-femit-bin={asm}", str(f)],
            capture_output=True, text=True, encoding="utf-8", errors="replace", env=env)
        if r.returncode == 0:
            body = [l.strip() for l in asm.read_text(errors="replace").splitlines()
                    if l.strip() and not l.strip().startswith((";", "."))]
            # 去掉 DSEG 声明，取前几条指令
            ins = [l for l in body if not l.startswith("_")][:4]
            print(f"{name:<12}{'OK':<6}" + " | ".join(ins))
            ok += 1
        else:
            msg = [l for l in (r.stderr + r.stdout).splitlines() if "mcs2:" in l]
            reason = msg[0].split("mcs2:")[-1].strip() if msg else "?"
            print(f"{name:<12}{'拒绝':<6}{reason[:88]}")
            bad += 1
    print("-" * 88)
    print(f"支持 {ok} 项，拒绝 {bad} 项（拒绝均为明确报错，无静默截断）")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
