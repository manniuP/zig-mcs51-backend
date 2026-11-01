#!/usr/bin/env python3
"""三方代码尺寸对比：mcs2 / SDCC 4.6 / Keil C51。

口径（和 docs/对比-与SDCC-Keil 一致）：
  - 同一段语义、同一组函数；函数体字节数 = 「首条指令 → RET」；
  - mcs2 与 SDCC 走同一条 sdas8051+sdld 链，尺寸从 .lst 量（fnsize.py）；
  - Keil 读编译 listing 的 MODULE INFORMATION: CODE SIZE（每文件只放一个函数）；
  - mcs2 侧复用 build/*.lst：先跑 python mcs2.py check <用例>。

⚠ 读数字时注意「内联 vs 库函数」：
  SDCC / Keil 把 32 位乘除、有符号除**下沉到库函数**（站点只有几字节的 lcall），
  库本身几百字节另算；mcs2 还没有 call（M2.5），所以每处**内联整段模板**。
  所以 u16 那几行是公平的内联对拼，u32 行要连库一起看。

环境变量：
  MCS_SDCC_BIN   SDCC 的 bin 目录（默认工作区内置工具链）
  KEIL_BIN       Keil C51 的 BIN 目录；未设置时 Keil 列显示「—」
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
from fnsize import ROW, fn_size                   # noqa: E402


def size_any(lst: Path, fn: str) -> int | None:
    """函数体尺寸。先走 fnsize 的 RET 口径；SDCC 的库尾调用（ljmp __mulint）没有 RET，
    退化成「首条指令 → 尾调用指令结束」。"""
    n = fn_size(lst, fn)
    if n is not None:
        return n
    lines = lst.read_text(errors="replace").splitlines()
    pat = re.compile(rf"\b_{re.escape(fn)}:\s*$")
    idx = next((i for i, l in enumerate(lines) if pat.search(l)), None)
    if idx is None:
        return None
    first = None
    end = None
    for line in lines[idx + 1:]:
        m = ROW.match(line)
        if not m:
            continue
        addr = int(m.group(1), 16)
        text = m.group(2).strip().upper()
        if first is None:
            first = addr
        if text.startswith("RET"):
            return addr + 1 - first
        if text.startswith("LJMP") or text.startswith("LCALL"):
            return addr + 3 - first
        if text.startswith("SJMP"):
            return addr + 2 - first
        end = addr + 1
    return None if (first is None or end is None) else end - first

# (标签, mcs2 的 .lst, mcs2 标签, C 文件, C 函数)
LEGACY = [
    ("add",         "add.lst",         "add",         "add.c",     "add"),
    ("sum",         "sum.lst",         "sum",         "sum.c",     "sum"),
    ("memrt",       "memrt.lst",       "memrt",       "memrt.c",   "memrt"),
    ("ringdemo",    "ringdemo.lst",    "ringdemo",    "ring.c",    "ringdemo"),
    ("sum_to_fold", "sum_to_fold.lst", "sum_to_fold", "fold.c",    "sum_to_fold"),
]

# 算术内核：每项一段单函数 C（Keil 要求一文件一函数）
ARITH = [
    ("u16add",  "u16add.lst",  "multi_u16add",   "unsigned int f(unsigned int a, unsigned int b) { return a + b; }"),
    ("u16mul",  "u16mul.lst",  "mul_u16mul",     "unsigned int f(unsigned int a, unsigned int b) { return a * b; }"),
    ("u16div",  "u16div.lst",  "div_u16div",     "unsigned int f(unsigned int a, unsigned int b) { return a / b; }"),
    ("u32add",  "u32add.lst",  "multi_u32add",   "unsigned long f(unsigned long a, unsigned long b) { return a + b; }"),
    ("u32mul",  "u32mul.lst",  "mul32_u32mul",   "unsigned long f(unsigned long a, unsigned long b) { return a * b; }"),
    ("u32div",  "u32div.lst",  "div32_u32div",   "unsigned long f(unsigned long a, unsigned long b) { return a / b; }"),
    ("u32rem",  "u32rem.lst",  "div32_u32rem",   "unsigned long f(unsigned long a, unsigned long b) { return a % b; }"),
    ("i32div",  "i32div.lst",  "sdiv_i32div",    "long f(long a, long b) { return a / b; }"),
    ("u32shl",  "shlv.lst",    "shiftv_shlv",    "unsigned long f(unsigned long a, unsigned char n) { return a << n; }"),
    ("u32shr",  "shrv.lst",    "shiftv_shrv",    "unsigned long f(unsigned long a, unsigned char n) { return a >> n; }"),
    ("sar32",   "sar32.lst",   "sar_sar32",      "long f(long a) { return a >> 3; }"),
    ("cmp32",   "ucmp_gt.lst", "wide_ucmp32",    "unsigned char f(unsigned long a, unsigned long b) { return a > b; }"),
    ("sexcmp",  "sexcmp.lst",  "signed_sexcmp",  "unsigned char f(signed char x) { long a = x; return a < -1; }"),
]


# 这一批是「真程序形状」的对照：switch / 条件表达式 / const 查表 / 间接调用 / CORDIC。
# (标签, mcs2 的 .lst, mcs2 标签, SDCC 的 C, Keil 的 C（缺省同 SDCC）)
NEW = [
    ("switch", "sw1h.lst", "switchex_sw1",
     "unsigned char f(unsigned char c) { unsigned char r = 0xEE;"
      " switch (c) { case 1: r = 0x11; break; case 2: r = 0x22; break; case 3: r = 0x33; break; }"
      " return r; }", None),
    ("ifexpr", "ifr1.lst", "ifexpr_ifr",
     "unsigned char f(unsigned char c) { return c ? 0x11 : 0x22; }", None),
    ("consttab", "cgeti.lst", "consttab_cgeti",
     "unsigned char f(unsigned char i) { static const unsigned char t[8] = {0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88}; return t[i]; }",
     "unsigned char f(unsigned char i) { static const unsigned char code t[8] = {0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88}; return t[i]; }"),
    ("indcall", "call_ind.lst", "indcall_call_ind",
     "unsigned char f(unsigned char (*p)(unsigned char), unsigned char x) { return p(x); }", None),
    ("cordic_sin", "csin90.lst", "cordic_sin",
     "int f(int a) {"
      " static const int at[12] = {8192,4836,2555,1297,651,326,163,81,41,20,10,5};"
      " int z = a, x = 9949, y = 0, i, q = 0;"
      " if (z > 0x4000) { z -= 0x4000; q = 1; } else if (z < -0x4000) { z += 0x4000; q = 2; }"
      " for (i = 0; i < 12; i++) { int xr = x >> i, yr = y >> i;"
      "   if (z >= 0) { x -= yr; y += xr; z -= at[i]; } else { x += yr; y -= xr; z += at[i]; } }"
      " if (q == 1) return x; if (q == 2) return -x; return y; }",
     "int f(int a) {"
      " static const int code at[12] = {8192,4836,2555,1297,651,326,163,81,41,20,10,5};"
      " int z = a, x = 9949, y = 0, i, q = 0;"
      " if (z > 0x4000) { z -= 0x4000; q = 1; } else if (z < -0x4000) { z += 0x4000; q = 2; }"
      " for (i = 0; i < 12; i++) { int xr = x >> i, yr = y >> i;"
      "   if (z >= 0) { x -= yr; y += xr; z -= at[i]; } else { x += yr; y -= xr; z += at[i]; } }"
      " if (q == 1) return x; if (q == 2) return -x; return y; }"),
]


def mcs2_dseg(tag: str) -> int | None:
    """mcs2 这一函数的静态 DSEG 字节数（每函数一块槽，含 PARM 区）。"""
    asm = BUILD / f"{tag}.asm"
    if not asm.exists():
        return None
    txt = asm.read_text(encoding="utf-8", errors="replace")
    return len(re.findall(r"^(_mcs_v\d+|_\w+_PARM_\d+): \.ds 1$", txt, re.M))

def sdcc_bin() -> Path:
    return toolchain_dir()


def _sdcc_size(c_path: Path, fn: str, tag: str) -> int | None:
    sdcc = sdcc_bin() / "sdcc.exe"
    if not sdcc.exists():
        return None
    asm = BUILD / f"{tag}_sdcc.asm"
    r = subprocess.run([str(sdcc), "-mmcs51", "--model-small", "-S",
                        "-o", str(asm), str(c_path)],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode != 0:
        print(r.stdout, r.stderr)
        return None
    # 只汇编、不链接：SDCC 的 32 位乘除会 lcall 库函数（__mululong 等），
    # 链接会报未定义；尺寸只要 .lst，sdas8051 单独跑就够。
    rel = asm.with_suffix(".rel")
    rr = subprocess.run([str(sdcc_bin() / "sdas8051.exe"), "-plosgffw", str(rel), str(asm)],
                        capture_output=True, text=True, encoding="utf-8", errors="replace")
    if rr.returncode != 0:
        print(rr.stdout[-400:], rr.stderr[-300:])
        return None
    return size_any(asm.with_suffix(".lst"), fn)


def _keil_sizes(src_text: str, tag: str) -> tuple[int | None, int | None]:
    """(CODE SIZE, DATA SIZE)。DATA 是静态分配（Keil 把局部量放寄存器/覆盖区，所以常是 0）；
    正好用来对照 mcs2 的「每函数一块静态 DSEG」。"""
    keil_bin = os.environ.get("KEIL_BIN", "")
    c51 = Path(keil_bin) / "C51.EXE" if keil_bin else None
    if not c51 or not c51.exists():
        return None
    KEIL_DIR.mkdir(parents=True, exist_ok=True)
    name = f"k_{tag}.c"
    (KEIL_DIR / name).write_text(src_text + "\n", encoding="ascii")
    lst = KEIL_DIR / name.replace(".c", ".lst")
    r = subprocess.run([str(c51), name, "SMALL", f"PRINT({lst.name})", "OPTIMIZE(8,SPEED)"],
                       cwd=KEIL_DIR, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    if r.returncode != 0 or not lst.exists():
        print(r.stdout[-400:], r.stderr[-200:])
        return (None, None)
    txt = lst.read_text(errors="replace")
    code = re.search(r"CODE SIZE\s*=\s*(\d+)", txt)
    data = re.search(r"DATA SIZE\s*=\s*(\d+)", txt)
    return (int(code.group(1)) if code else None, int(data.group(1)) if data else 0)


def _row(tag: str, ours: int | None, sd: int | None, kl: int | None, note: str) -> str:
    fmt = lambda v: f"{v} B" if v is not None else "—"
    ratio = ""
    if ours is not None and sd:
        ratio = f"  mcs2/SDCC={ours / sd:.2f}"
    return f"{tag:<12}{fmt(ours):>8}{fmt(sd):>9}{fmt(kl):>9}   {note}{ratio}"


def main() -> int:
    have_keil = bool(os.environ.get("KEIL_BIN"))
    if not have_keil:
        cand = Path(os.path.expandvars(r"%LOCALAPPDATA%\Keil_v5\C51\BIN"))
        if (cand / "C51.EXE").exists():
            os.environ["KEIL_BIN"] = str(cand)
            have_keil = True
            print(f"（自动发现 Keil：{cand}）")
    print(f"{'用例':<12}{'mcs2':>8}{'SDCC 4.6':>9}{'Keil C51':>9}   备注")
    print("-" * 76)
    for tag, lst_name, label, c_file, c_fn in LEGACY:
        ours = fn_size(BUILD / lst_name, label)
        sd = _sdcc_size(CB / c_file, c_fn, tag)
        kl = _keil_sizes((CB / c_file).read_text(encoding="utf-8"), tag)[0] if have_keil else None
        note = "PE 折叠（循环消失）" if tag == "sum_to_fold" else ""
        print(_row(tag, ours, sd, kl, note))
    print("-" * 76)
    for tag, lst_name, label, c_one in ARITH:
        ours = fn_size(BUILD / lst_name, label)
        c_path = BUILD / f"{tag}_c.c"
        c_path.write_text(c_one + "\n", encoding="ascii")
        sd = _sdcc_size(c_path, "f", tag)
        kl = _keil_sizes(c_one, tag)[0] if have_keil else None
        note = ""
        if tag in ("u16mul", "u16div", "u32mul", "u32div", "u32rem", "i32div"):
            note = "SDCC/Keil 走库函数，mcs2 内联"
        print(_row(tag, ours, sd, kl, note))
    print("-" * 76)
    print("真程序形状（switch / 条件表达式 / const 查表 / 间接调用 / CORDIC）")
    print(f"{'用例':<12}{'mcs2':>8}{'SDCC 4.6':>9}{'Keil C51':>9}{'mcs2 DSEG':>11}{'Keil DATA':>11}")
    print("-" * 76)
    for tag, lst_name, label, c_sdcc, c_keil in NEW:
        ours = fn_size(BUILD / lst_name, label)
        c_path = BUILD / f"new_{tag}_c.c"
        c_path.write_text(c_sdcc + "\n", encoding="ascii")
        sd = _sdcc_size(c_path, "f", f"new_{tag}")
        kl = None
        kd = None
        if have_keil:
            kl, kd = _keil_sizes(c_keil or c_sdcc, f"new_{tag}")
        dseg = mcs2_dseg(lst_name.replace(".lst", ""))
        fmt = lambda v: f"{v} B" if v is not None else "—"
        print(f"{tag:<12}{fmt(ours):>8}{fmt(sd):>9}{fmt(kl):>9}{fmt(dseg):>11}{fmt(kd):>11}")
    if not have_keil:
        print("\n（Keil 列未采集：设置 KEIL_BIN=<Keil\\C51\\BIN> 后重跑）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
