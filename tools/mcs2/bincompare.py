#!/usr/bin/env python3
"""HEX/IHX → BIN 的实际固件体积对比（mcs2 / SDCC / Keil）。

为什么还要一张表：`bench_compare.py` 量函数体，`fwsize.py` 量「数据字节之和」，
两者都**看不见地址空洞**。而烧进 Flash 的是从最低地址到最高地址的连续块，
中间的空洞也要占位（0xFF）。本脚本把三方产物真的转成 .bin，按落盘字节数比。

口径：
  * 有效字节 = HEX 里 0x00 数据记录的字节数之和（与 fwsize 的 ROM 同口径）；
  * BIN 体积 = max_addr - min_addr + 1，空洞填 0xFF（＝实际占用的 Flash 跨度）；
  * HEX 文本  = 磁盘上 .ihx/.hex 的文件大小（对照用，说明文本格式的膨胀率）。

Intel HEX 记录类型：00 数据 / 01 结束 / 02 段地址 / 04 线性地址（后两者改高位）。
交叉核对：本脚本的「有效字节」应与 `fwsize.py` 的 ROM 列完全一致。
"""
from __future__ import annotations

import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import fwsize  # noqa: E402
import mcs2  # noqa: E402

BUILD = HERE / "build" / "bincmp"
ZIG = fwsize.ZIG
SDCC_BIN = fwsize.SDCC_BIN


def parse_hex(p: Path) -> dict[int, int]:
    """Intel HEX → {绝对地址: 字节}。高位地址由 02/04 记录提供。"""
    mem: dict[int, int] = {}
    base = 0
    for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line.startswith(":"):
            continue
        try:
            rec = bytes.fromhex(line[1:])
        except ValueError:
            continue
        if len(rec) < 5:
            continue
        n, typ = rec[0], rec[3]
        if len(rec) != n + 5:          # 校验和本身不验证，长度不符直接跳过
            continue
        payload = rec[4:4 + n]
        off = (rec[1] << 8) | rec[2]
        if typ == 0x00:
            for i, b in enumerate(payload):
                mem[base + off + i] = b
        elif typ == 0x01:
            break
        elif typ == 0x02:
            base = ((payload[0] << 8) | payload[1]) << 4
        elif typ == 0x04:
            base = ((payload[0] << 8) | payload[1]) << 16
    return mem


def to_bin(mem: dict[int, int]) -> tuple[bytes, int, int, int]:
    """→ (bin 字节, 低地址, 高地址, 空洞字节数)。空洞按 0xFF 填充。"""
    lo, hi = min(mem), max(mem)
    span = hi - lo + 1
    buf = bytearray(b"\xff" * span)
    for a, b in mem.items():
        buf[a - lo] = b
    return bytes(buf), lo, hi, span - len(mem)


def report(p: Path, out: Path | None = None) -> dict:
    mem = parse_hex(p)
    if not mem:
        return {}
    data, lo, hi, holes = to_bin(mem)
    if out is not None:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(data)
    return {
        "hex_text": p.stat().st_size,
        "used": len(mem),
        "bin": len(data),
        "lo": lo,
        "hi": hi,
        "holes": holes,
        "path": out,
    }


def mcs2_build(tag: str, spec: dict) -> Path | None:
    d = BUILD / f"z_{tag}"
    d.mkdir(parents=True, exist_ok=True)
    src = d / "f.zig"
    src.write_text(spec["zig"] + "\n", encoding="utf-8")
    asm = d / "f.asm"
    r = subprocess.run(
        [str(ZIG), "build-obj", "-OReleaseSmall", "-target", "mcs51-freestanding",
         f"-femit-bin={asm}", str(src)],
        capture_output=True, text=True, encoding="utf-8", errors="replace",
    )
    if r.returncode != 0:
        print(r.stdout[-300:], r.stderr[-300:])
        return None
    body = asm.read_text(errors="replace")
    harness = ("    .area CSEG (CODE)\n    ljmp _crt\n_crt:\n    mov sp,#0x7F\n"
               + spec["args"] + "    lcall _f\n    mov 0x82,a\n    sjmp .\n")
    merged = mcs2.merge(f"bc_{tag}", harness, body)
    return mcs2.assemble(merged, f"bc_{tag}", dseg=0x30, cseg=0x0000)


def sdcc_build(tag: str, spec: dict) -> Path | None:
    d = BUILD / f"s_{tag}"
    d.mkdir(parents=True, exist_ok=True)
    src = d / "p.c"
    src.write_text(fwsize.C_HEAD + spec["c"] + "\n", encoding="ascii")
    ihx = d / "p.ihx"
    r = subprocess.run(
        [str(SDCC_BIN / "sdcc.exe"), "-mmcs51", "--model-small", str(src), "-o", str(ihx)],
        capture_output=True, text=True, encoding="utf-8", errors="replace",
    )
    if r.returncode != 0 or not ihx.exists():
        print(r.stdout[-300:], r.stderr[-300:])
        return None
    return ihx


def keil_build(tag: str, spec: dict) -> Path | None:
    kb = fwsize.keil_bin()
    if kb is None:
        return None
    d = BUILD / f"k_{tag}"
    d.mkdir(parents=True, exist_ok=True)
    src = d / "p.c"
    src.write_text(fwsize.C_HEAD + spec["c"] + "\n", encoding="ascii")
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
    # BL51 的输入是逗号分隔的一整串（分开传 argv 不认），产出无扩展名的绝对目标 + .M51。
    r = subprocess.run([str(kb / "BL51.EXE"), f"p.OBJ,STARTUP.OBJ,{libs}"],
                       cwd=d, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    if r.returncode != 0:
        out = ((r.stdout or "") + (r.stderr or "")).strip()
        print("  [keil BL51] " + (out.splitlines()[-1] if out else "failed"))
        return None
    # HEX 不由 BL51 产出，要走 OH51 把 OMF51 转成 Intel HEX。
    oh = kb / "OH51.EXE"
    if not oh.exists():
        return None
    subprocess.run([str(oh), "P"], cwd=d, capture_output=True, text=True,
                   encoding="utf-8", errors="replace")
    cands = sorted(d.glob("*.hex")) + sorted(d.glob("*.HEX"))
    return cands[0] if cands else None


def fmt(v: int | None) -> str:
    return "—" if v is None else str(v)


def main() -> int:
    BUILD.mkdir(parents=True, exist_ok=True)
    have_keil = fwsize.keil_bin() is not None
    rows = []
    for tag, spec in fwsize.CASES.items():
        z = mcs2_build(tag, spec)
        s = sdcc_build(tag, spec)
        k = keil_build(tag, spec) if have_keil else None
        rows.append((
            tag,
            report(z, BUILD / "bin" / f"mcs2_{tag}.bin") if z else {},
            report(s, BUILD / "bin" / f"sdcc_{tag}.bin") if s else {},
            report(k, BUILD / "bin" / f"keil_{tag}.bin") if k else {},
        ))

    print("\n== 一、同一份产物：HEX 文本 vs 转 BIN 之后的体积")
    print(f"{'用例':<10}{'来源':<7}{'HEX文本':>9}{'有效':>7}{'BIN':>7}{'空洞':>7}{'膨胀':>7}")
    print("-" * 56)
    for tag, z, s, k in rows:
        for src, r in (("mcs2", z), ("SDCC", s), ("Keil", k)):
            if not r:
                continue
            ratio = r["hex_text"] / r["bin"]
            print(f"{tag:<10}{src:<7}{r['hex_text']:>9}{r['used']:>7}"
                  f"{r['bin']:>7}{r['holes']:>7}{ratio:>6.2f}x")

    print("\n== 二、三方 BIN 体积（实际占用 Flash 跨度）")
    print(f"{'用例':<10}{'mcs2':>8}{'SDCC':>8}{'Keil':>8}{'mcs2/SDCC':>11}")
    print("-" * 46)
    for tag, z, s, k in rows:
        zb, sb, kb2 = z.get("bin"), s.get("bin"), k.get("bin")
        ratio = f"{zb / sb:.2f}x" if (zb and sb) else "—"
        print(f"{tag:<10}{fmt(zb):>8}{fmt(sb):>8}{fmt(kb2):>8}{ratio:>11}")

    base = rows[0]
    print("\n== 三、相对空壳基线的增量（= 这个算子的真实代价）")
    print(f"{'用例':<10}{'mcs2':>8}{'SDCC':>8}{'Keil':>8}")
    print("-" * 34)
    for tag, z, s, k in rows:
        def d(r: dict, b: dict) -> str:
            if not r or not b:
                return "—"
            return f"{r['bin'] - b['bin']:+d}"
        print(f"{tag:<10}{d(z, base[1]):>8}{d(s, base[2]):>8}{d(k, base[3]):>8}")

    nb = BUILD / "bin"
    print(f"\nBIN 文件已写到 {nb.relative_to(HERE.parents[1])}/")
    print("注：mcs2 无 call（M2.5），乘除是内联模板；SDCC/Keil 的增量含被拉进来的库。")
    if not have_keil:
        print("（Keil 列未采集：设置 KEIL_BIN=<Keil\\C51\\BIN>）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
