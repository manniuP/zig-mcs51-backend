#!/usr/bin/env python3
"""SFR 结构化工具：把厂商头文件解析成设备模型可用的寄存器表。

支持两种输入：
  - Keil 头：`sfr NAME = 0xNN;` / `sbit NAME = BASE^n;` / `#define N (*(unsigned char volatile far *)0xNNNNNN)`
  - SDCC 头：`SFR(NAME, 0xNN);` / `SBIT(NAME, 0xNN);` / `#define N (*(unsigned char volatile __xdata *)0xNNNN)`

输出（--emit）：
  toml  生成 `[sfr]` / `[sfr_bits]` / `[xfr]` 片段（可并入设备 TOML）
  c     生成 SDCC 头（SFR()/SBIT()/__xdata 指针）
  zig   生成 Zig comptime 寄存器地址模块
  check 校验设备 TOML 里的 `[registers]`/`[register_bits]`/`[xfr]` 与该头是否一致
  stat  打印统计

示例：
  python tools/mcs_sfr.py --input tools/vendor/stc/AI8051U.keil.h --emit stat
  python tools/mcs_sfr.py --input tools/vendor/stc/AI8051U.keil.h \
      --check devices/stc/ai8051u-34k64.toml --emit check
  python tools/mcs_sfr.py --input tools/vendor/stc/AI8051U.keil.h --emit toml
  python tools/mcs_sfr.py --self-test
"""

from __future__ import annotations

import argparse
import re
import sys
import tomllib
from pathlib import Path

RE_KEIL_SFR = re.compile(r"^\s*sfr\s+(\w+)\s*=\s*(0x[0-9A-Fa-f]+)\s*;")
RE_KEIL_SBIT = re.compile(r"^\s*sbit\s+(\w+)\s*=\s*(\w+)\s*\^\s*(\d+)\s*;")
RE_SDCC_SFR = re.compile(r"^\s*SFR\(\s*(\w+)\s*,\s*(0x[0-9A-Fa-f]+)\s*\)")
RE_SDCC_SBIT = re.compile(r"^\s*SBIT\(\s*(\w+)\s*,\s*(0x[0-9A-Fa-f]+)(?:\s*,)?")
RE_XFR = re.compile(
    r"^\s*#define\s+(\w+)\s+\(\*\(\s*unsigned\s+(?:char|int)\s+volatile\s+(?:far|xdata|__xdata)\s*\*\s*\)\s*(0x[0-9A-Fa-f]+)\s*\)")


def read_text_auto(path: Path) -> str:
    data = path.read_bytes()
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.decode("gbk", errors="replace")


def parse_header(path: Path) -> dict:
    """返回 {sfr:{name:addr}, bits:{name:bitaddr}, xfr:{name:addr}, kind:keil|sdcc}."""
    sfr: dict[str, int] = {}
    bit_base: dict[str, tuple[str, int]] = {}   # name -> (base, bit)
    sbit_addr: dict[str, int] = {}
    xfr: dict[str, int] = {}
    kind = "keil"
    for ln in re.split(r"\r?\n", read_text_auto(path)):
        m = RE_KEIL_SFR.match(ln)
        if m:
            sfr[m.group(1)] = int(m.group(2), 16)
            continue
        m = RE_SDCC_SFR.match(ln)
        if m:
            kind = "sdcc"
            sfr[m.group(1)] = int(m.group(2), 16)
            continue
        m = RE_KEIL_SBIT.match(ln)
        if m:
            bit_base[m.group(1)] = (m.group(2), int(m.group(3)))
            continue
        m = RE_SDCC_SBIT.match(ln)
        if m:
            kind = "sdcc"
            sbit_addr[m.group(1)] = int(m.group(2), 16)
            continue
        m = RE_XFR.match(ln)
        if m:
            xfr[m.group(1)] = int(m.group(2), 16)
    # sbit(base^bit)：基址为 8 的倍数 → 真位地址；否则退化为掩码
    masks: dict[str, tuple[str, int, int]] = {}
    for name, (base, bit) in bit_base.items():
        if base in sfr and sfr[base] % 8 == 0:
            sbit_addr[name] = sfr[base] + bit
        elif base in sfr:
            masks[name] = (base, bit, 1 << bit)
    return {"sfr": sfr, "bits": sbit_addr, "masks": masks, "xfr": xfr, "kind": kind}


# ---------------------------------------------------------------------------
# emit
# ---------------------------------------------------------------------------


def emit_toml(parsed: dict) -> str:
    out = ["# 由 tools/mcs_sfr.py 生成（可直接并入设备 TOML）", "[sfr]"]
    for name, addr in sorted(parsed["sfr"].items(), key=lambda kv: kv[1]):
        out.append(f"{name} = {addr:#04x}")
    out.append("")
    out.append("[sfr_bits]")
    for name, addr in sorted(parsed["bits"].items(), key=lambda kv: kv[1]):
        out.append(f'"{name}" = {addr:#04x}')
    out.append("")
    out.append("# 基址非 8 倍数的 SFR 位：不可位寻址，用掩码（|= / &=~）")
    out.append("[sfr_masks]")
    for name, (_base, _bit, mask) in sorted(parsed["masks"].items()):
        out.append(f'"{name}" = {mask:#04x}')
    out.append("")
    out.append("[xfr]")
    for name, addr in sorted(parsed["xfr"].items(), key=lambda kv: kv[1]):
        out.append(f"{name} = {addr:#08x}")
    return "\n".join(out) + "\n"


def emit_c(parsed: dict) -> str:
    name = "mcs_sfr_generated"
    out = [f"/* 由 tools/mcs_sfr.py 生成 */", f"#ifndef {name.upper()}_H", f"#define {name.upper()}_H", '#include "c51.h"', ""]
    for n, a in sorted(parsed["sfr"].items(), key=lambda kv: kv[1]):
        out.append(f"SFR({n}, {a:#04x});")
    out.append("")
    for n, a in sorted(parsed["bits"].items(), key=lambda kv: kv[1]):
        out.append(f"SBIT({n}, {a:#04x});")
    out.append("")
    out.append("/* 基址非 8 倍数：SDCC 不能位寻址，退化为掩码（用 |= / &=~） */")
    for n, (_base, _bit, mask) in sorted(parsed["masks"].items()):
        out.append(f"#define {n} {mask:#04x}")
    out.append("")
    out.append("/* XFR：需先 EAXFR=1；用 xdata 指针访问 */")
    for n, a in sorted(parsed["xfr"].items(), key=lambda kv: kv[1]):
        out.append(f"#define {n} (*(volatile unsigned char __xdata *){a:#x})")
    out.append("")
    out.append(f"#endif /* {name.upper()}_H */")
    return "\n".join(out) + "\n"


def emit_zig(parsed: dict) -> str:
    out = ["// 由 tools/mcs_sfr.py 生成：SFR/XFR 地址（comptime 常量）", "", "pub const sfr = struct {"]
    for n, a in sorted(parsed["sfr"].items(), key=lambda kv: kv[1]):
        out.append(f"    pub const {n}: u16 = {a:#04x};")
    out.append("};")
    out.append("")
    out.append("pub const xfr = struct {")
    for n, a in sorted(parsed["xfr"].items(), key=lambda kv: kv[1]):
        out.append(f"    pub const {n}: u32 = {a:#08x};")
    out.append("};")
    out.append("")
    out.append("pub const bit = struct {")
    for n, a in sorted(parsed["bits"].items(), key=lambda kv: kv[1]):
        out.append(f"    pub const {n}: u8 = {a:#04x};")
    out.append("};")
    out.append("")
    out.append("pub const mask = struct {")
    for n, (_base, _bit, mask) in sorted(parsed["masks"].items()):
        out.append(f"    pub const {n}: u8 = {mask:#04x};")
    out.append("};")
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------


def check_device(device_path: Path, parsed: dict) -> list[str]:
    with device_path.open("rb") as f:
        doc = tomllib.load(f)
    problems: list[str] = []
    sfr, bits, xfr = parsed["sfr"], parsed["bits"], parsed["xfr"]

    for name, addr in (doc.get("registers") or {}).items():
        if name in sfr:
            if int(addr) != sfr[name]:
                problems.append(f"registers.{name}: 设备 {int(addr):#x} ≠ 头 {sfr[name]:#x}")
        elif name in xfr:
            if int(addr) != xfr[name]:
                problems.append(f"registers.{name}: 设备 {int(addr):#x} ≠ XFR 头 {xfr[name]:#x}")
        else:
            problems.append(f"registers.{name}: 头文件中未找到")

    for key, bitpos in (doc.get("register_bits") or {}).items():
        reg = key.split(".")[0]
        if reg not in sfr and reg not in xfr:
            problems.append(f"register_bits.{key}: 基址寄存器 {reg} 未找到")
            continue
        if not (0 <= int(bitpos) <= 7):
            problems.append(f"register_bits.{key}: 位号 {bitpos} 越界")

    for name, addr in (doc.get("xfr") or {}).items():
        if name in xfr:
            if int(addr) != xfr[name]:
                problems.append(f"xfr.{name}: 设备 {int(addr):#x} ≠ 头 {xfr[name]:#x}")
        else:
            problems.append(f"xfr.{name}: 头文件中未找到")
    return problems


# ---------------------------------------------------------------------------
# self-test
# ---------------------------------------------------------------------------


def _self_test() -> int:
    root = Path(__file__).resolve().parent.parent
    cases = [
        (root / "tools/vendor/stc/AI8051U.keil.h", "keil",
         {"P0": 0x80, "SP": 0x81, "P_SW2": 0xBA, "CLKSEL": 0x7EFE00},
         {"P00": 0x80, "TF0": 0x8D},
         {"EAXFR": ("P_SW2", 7), "EXTRAM": ("AUXR", 1)}),
        (root / "tools/vendor/stc/stc8h_SDCC_C51.h", "sdcc",
         {"P0": 0x80, "IAP_CONTR": 0xC7, "CLKSEL": 0xFE00},
         {}, {}),
    ]
    failed = 0
    for path, kind, sfr_want, bit_want, mask_want in cases:
        if not path.is_file():
            print(f"SKIP {path.name}")
            continue
        p = parse_header(path)
        if p["kind"] != kind:
            print(f"FAIL {path.name}: kind={p['kind']} 期望 {kind}")
            failed += 1
            continue
        for n, a in sfr_want.items():
            got = p["sfr"].get(n, p["xfr"].get(n))
            if got != a:
                print(f"FAIL {path.name}: {n}={got} 期望 {a:#x}")
                failed += 1
        for n, a in bit_want.items():
            if p["bits"].get(n) != a:
                print(f"FAIL {path.name}: bit {n}={p['bits'].get(n)} 期望 {a:#x}")
                failed += 1
        for n, (base, bit) in mask_want.items():
            got = p["masks"].get(n)
            if not got or got[0] != base or got[1] != bit:
                print(f"FAIL {path.name}: mask {n}={got} 期望 ({base},{bit})")
                failed += 1
        print(f"ok   {path.name}: sfr={len(p['sfr'])} sbit={len(p['bits'])} "
              f"mask={len(p['masks'])} xfr={len(p['xfr'])}")

    # 校验完整设备文件（按各自的 sfr_source 解析）
    for dev in (root / "devices/stc/ai8051u-34k64.toml", root / "devices/stc/stc8h8k64u.toml"):
        with dev.open("rb") as f:
            doc = tomllib.load(f)
        src = (doc.get("device") or {}).get("sfr_source", "")
        hdr = (dev.parent / src).resolve()
        if not hdr.is_file():
            failed += 1
            print(f"FAIL check {dev.name}: 头不存在 {hdr}")
            continue
        probs = check_device(dev, parse_header(hdr))
        if probs:
            failed += 1
            print(f"FAIL check {dev.name}:")
            for x in probs:
                print("      " + x)
        else:
            print(f"ok   check {dev.name}")
    if failed:
        print(f"\n{failed} 项失败")
        return 1
    print("\nmcs_sfr self-test passed")
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input", type=Path, help="厂商头文件")
    ap.add_argument("--device", type=Path, help="按设备 TOML 的 sfr_source 解析并校验（与 --input 二选一）")
    ap.add_argument("--emit", default=None, choices=["stat", "toml", "c", "zig", "check"])
    ap.add_argument("--check", type=Path, help="--emit check 时的设备 TOML")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv)

    if args.self_test:
        return _self_test()

    # 解析：--device 时按其 sfr_source 找头；否则用 --input。
    if args.device:
        if not args.device.is_file():
            ap.error(f"设备文件不存在: {args.device}")
        with args.device.open("rb") as f:
            doc = tomllib.load(f)
        src = (doc.get("device") or {}).get("sfr_source")
        if not src:
            print(f"{args.device.name}: 无 sfr_source")
            return 0
        hdr = (args.device.parent / src).resolve()
        if not hdr.is_file():
            print(f"{args.device.name}: 头文件不存在 {hdr}")
            return 1
        parsed = parse_header(hdr)
    elif args.input and args.input.is_file():
        parsed = parse_header(args.input)
    else:
        ap.error("需要 --input 厂商头文件 或 --device 设备 TOML")

    emit = args.emit or ("check" if args.device else "stat")
    if emit == "check":
        target = args.check or args.device
        if not target or not target.is_file():
            ap.error("--emit check 需要 --device 或 --check 设备 TOML")
        probs = check_device(target, parsed)
        for x in probs:
            print(x)
        if not probs:
            print(f"ok {target.name}")
        return 1 if probs else 0
    if emit == "stat":
        print(f"kind: {parsed['kind']}")
        print(f"直接 SFR : {len(parsed['sfr'])}")
        print(f"可位寻址位: {len(parsed['bits'])}")
        print(f"XFR      : {len(parsed['xfr'])}")
    elif emit == "toml":
        sys.stdout.write(emit_toml(parsed))
    elif emit == "c":
        sys.stdout.write(emit_c(parsed))
    elif emit == "zig":
        sys.stdout.write(emit_zig(parsed))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
