#!/usr/bin/env python3
"""总固件尺寸对比：mcs2 / SDCC / Keil 各自「整个程序」占多少 Flash，以及库占多少。

为什么还要一张表：bench_compare.py 量的是**函数体**，而 SDCC/Keil 把 16/32 位乘除
下沉到**库函数**（站点只有几字节），库本身几百字节另算。所以真问题不是「函数体 15 B vs 188 B」，
而是「同功能固件总共占多少」——本脚本量这个。

口径：
  * 每个用例编一个**完整程序**：固定参数算一次，结果写 volatile 全局，然后 while(1)。
  * 「总 ROM」= .ihx 里所有数据字节之和（代码 + 常量）。
  * 基线程序 = 同样结构但不做运算（直接写常量），Δ = 用例 − 基线
    → Δ 里包含**内联代码 + 被拉进来的库**，这才是「这个算子真实代价」。
  * mcs2 侧没有 call（M2.5），所以外壳是汇编：mov sp / 摆参 / lcall / sjmp .
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BUILD = HERE / "build" / "total"
WORKSPACE = HERE.parents[2]
ZIG = WORKSPACE / "zig017" / "mcs2build" / "zig-out" / "bin" / "zig.exe"
SDCC_BIN = Path(os.environ.get("MCS_SDCC_BIN", WORKSPACE / "mcs251" / "tools" /
                               "sdcc-mcs251-windows-x64" / "sdcc-mcs251" / "bin"))
sys.path.insert(0, str(HERE))
import mcs2  # noqa: E402


def keil_bin() -> Path | None:
    env = os.environ.get("KEIL_BIN", "")
    if env and (Path(env) / "C51.EXE").exists():
        return Path(env)
    cand = Path(os.path.expandvars(r"%LOCALAPPDATA%\Keil_v5\C51\BIN"))
    return cand if (cand / "C51.EXE").exists() else None


def hex_bytes(p: Path) -> int:
    """.ihx/.hex 里数据字节总数（含地址扩展记录之后的净数据）。"""
    n = 0
    for line in p.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line.startswith(":"):
            continue
        try:
            cnt = int(line[1:3], 16)
            typ = int(line[7:9], 16)
        except ValueError:
            continue
        if typ == 0:
            n += cnt
    return n


# 用例：名字 → (Zig 源, C 源, mcs2 摆参 asm)
CASES: dict[str, dict] = {
    "baseline": dict(
        zig="export fn f() u8 { return 0x5A; }",
        c="void main(void){ o = 0x5A; while(1){} }",
        args=""),
    "u16mul": dict(
        zig="export fn f(a: u16, b: u16) u16 { return a *% b; }",
        c="void main(void){ o = (unsigned int)vi_a * (unsigned int)vi_b; while(1){} }",
        args="    mov dpl,#0x34\n    mov dph,#0x12\n    mov _f_PARM_2,#0x56\n    mov _f_PARM_3,#0x00\n"),
    "u16div": dict(
        zig="export fn f(a: u16, b: u16) u16 { return a / b; }",
        c="void main(void){ o = (unsigned int)vi_a / (unsigned int)vi_b; while(1){} }",
        args="    mov dpl,#0x34\n    mov dph,#0x12\n    mov _f_PARM_2,#0x56\n    mov _f_PARM_3,#0x00\n"),
    "u32mul": dict(
        zig="export fn f(a: u32, b: u32) u32 { return a *% b; }",
        c="void main(void){ o = vl_a * vl_b; while(1){} }",
        args="    mov dpl,#0x78\n    mov dph,#0x56\n    mov b,#0x34\n    mov acc,#0x12\n"
             "    mov _f_PARM_2,#0xFF\n    mov _f_PARM_3,#0x00\n    mov _f_PARM_4,#0x00\n    mov _f_PARM_5,#0x00\n"),
    "u32div": dict(
        zig="export fn f(a: u32, b: u32) u32 { return a / b; }",
        c="void main(void){ o = vl_a / vl_b; while(1){} }",
        args="    mov dpl,#0x78\n    mov dph,#0x56\n    mov b,#0x34\n    mov acc,#0x12\n"
             "    mov _f_PARM_2,#0xFF\n    mov _f_PARM_3,#0x00\n    mov _f_PARM_4,#0x00\n    mov _f_PARM_5,#0x00\n"),
    "i32div": dict(
        zig="export fn f(a: i32, b: i32) i32 { return @divTrunc(a, b); }",
        c="void main(void){ o = (long)vl_a / (long)vl_b; while(1){} }",
        args="    mov dpl,#0x78\n    mov dph,#0x56\n    mov b,#0x34\n    mov acc,#0x12\n"
             "    mov _f_PARM_2,#0x07\n    mov _f_PARM_3,#0x00\n    mov _f_PARM_4,#0x00\n    mov _f_PARM_5,#0x00\n"),
    "sar32": dict(
        zig="export fn f(a: i32) i32 { return a >> 3; }",
        c="void main(void){ o = (long)vl_a >> vi_b; while(1){} }",
        args="    mov dpl,#0x78\n    mov dph,#0x56\n    mov b,#0x34\n    mov acc,#0x12\n"),
}

# C 侧必须让操作数是**运行期**的（volatile 全局），否则编译器把整个运算折叠掉，
# 量出来的 Δ 会是 0——那就完全测不到库函数。
C_HEAD = ("volatile unsigned long o;\n"
          "volatile unsigned int  vi_a, vi_b;\n"
          "volatile unsigned long vl_a, vl_b;\n")


def mcs2_rom(tag: str, spec: dict) -> int | None:
    d = BUILD / f"z_{tag}"
    d.mkdir(parents=True, exist_ok=True)
    src = d / "f.zig"
    src.write_text(spec["zig"] + "\n", encoding="utf-8")
    asm = d / "f.asm"
    r = subprocess.run([str(ZIG), "build-obj", "-OReleaseSmall", "-target", "mcs51-freestanding",
                        f"-femit-bin={asm}", str(src)], capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    if r.returncode != 0:
        print(r.stdout[-300:], r.stderr[-300:])
        return None
    body = asm.read_text(errors="replace")
    harness = ("    .area CSEG (CODE)\n    ljmp _crt\n_crt:\n    mov sp,#0x7F\n"
               + spec["args"] + "    lcall _f\n    mov 0x82,a\n    sjmp .\n")
    merged = mcs2.merge(f"tot_{tag}", harness, body)
    ihx = mcs2.assemble(merged, f"tot_{tag}", dseg=0x30, cseg=0x0000)
    return hex_bytes(ihx)


def sdcc_rom(tag: str, spec: dict) -> int | None:
    d = BUILD / f"s_{tag}"
    d.mkdir(parents=True, exist_ok=True)
    src = d / "p.c"
    src.write_text(C_HEAD + spec["c"] + "\n", encoding="ascii")
    ihx = d / "p.ihx"
    r = subprocess.run([str(SDCC_BIN / "sdcc.exe"), "-mmcs51", "--model-small",
                        str(src), "-o", str(ihx)], capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    if r.returncode != 0 or not ihx.exists():
        print(r.stdout[-300:], r.stderr[-300:])
        return None
    return hex_bytes(ihx)


def keil_rom(tag: str, spec: dict) -> int | None:
    kb = keil_bin()
    if kb is None:
        return None
    d = BUILD / f"k_{tag}"
    d.mkdir(parents=True, exist_ok=True)
    src = d / "p.c"
    src.write_text(C_HEAD + spec["c"] + "\n", encoding="ascii")
    # Keil 的 C 程序必须显式链 STARTUP.A51（uVision 会自动加，命令行不会）
    startup_src = kb.parent / "LIB" / "STARTUP.A51"
    if not (d / "STARTUP.A51").exists() and startup_src.exists():
        shutil.copyfile(startup_src, d / "STARTUP.A51")
    steps = [[str(kb / "C51.EXE"), "p.c", "SMALL", "OPTIMIZE(8,SPEED)"]]
    if (d / "STARTUP.A51").exists():
        steps.append([str(kb / "A51.EXE"), "STARTUP.A51"])
    for cmd in steps:
        rr = subprocess.run(cmd, cwd=d, capture_output=True, text=True,
                            encoding="utf-8", errors="replace")
        if rr.returncode != 0:
            print(f"  [keil {Path(cmd[0]).name}] {((rr.stdout or '') + (rr.stderr or ''))[-200:]}")
            return None
    libs = kb.parent / "LIB" / "C51S.LIB"
    # BL51 的输入是**逗号分隔的一整串**，分开传 argv 不认；输出用默认绝对目标，
    # 尺寸从它生成的 .M51 映射表里读 CODE 段。
    argline = f"p.OBJ,STARTUP.OBJ,{libs}"
    r = subprocess.run([str(kb / "BL51.EXE"), argline], cwd=d, capture_output=True,
                       text=True, encoding="utf-8", errors="replace")
    maps = sorted(d.glob("*.M51")) + sorted(d.glob("*.m51"))
    if r.returncode != 0 or not maps:
        out = ((r.stdout or "") + (r.stderr or "")).strip()
        print("  [keil BL51] " + (out.splitlines()[-1] if out else "failed"))
        return None
    text = maps[0].read_text(errors="replace")
    # 映射表末尾有汇总行：Program Size: data=25.0 xdata=0 code=123
    m = re.search(r"Program Size:.*?code=(\d+)", text)
    if not m:
        print("  [keil BL51] 映射表里没找到 Program Size/code")
        return None
    return int(m.group(1))


def main() -> int:
    BUILD.mkdir(parents=True, exist_ok=True)
    have_keil = keil_bin() is not None
    rows = []
    for tag, spec in CASES.items():
        rows.append((tag, mcs2_rom(tag, spec), sdcc_rom(tag, spec),
                     keil_rom(tag, spec) if have_keil else None))
    base = rows[0]
    if base[1] is None or base[2] is None:
        print("基线程序编不出来，没法算 Δ")
    print(f"\n{'用例':<10}{'mcs2':>8}{'SDCC':>8}{'Keil':>8}   | Δ(相对基线)")
    print("-" * 66)
    for tag, z, s, k in rows:
        def d(v, b):
            return f"{v - b:+d}" if (v is not None and b is not None) else "—"
        cells = f"{z if z is not None else '—':>8}{s if s is not None else '—':>8}{k if k is not None else '—':>8}"
        dd = f"{d(z, base[1]):>7}{d(s, base[2]):>8}{d(k, base[3]):>8}"
        print(f"{tag:<10}{cells}   |{dd}")
    print("\n注：mcs2 没有 call（M2.5），乘除模板是内联；SDCC/Keil 的 Δ 里含被拉进来的库函数。")
    if not have_keil:
        print("（Keil 列未采集：设置 KEIL_BIN=<Keil\\C51\\BIN>）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
