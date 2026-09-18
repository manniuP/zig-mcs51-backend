#!/usr/bin/env python3
"""把 STC 的 Keil C51/C251 头文件翻译为 SDCC 可用形式。

用法：
    python tools/keil2sdcc.py \
        --input-file tools/vendor/stc/AI8051U.keil.h \
        --output-file lib/include/ai8051u_sfr.h

规则：
    sfr  NAME = 0xNN;            -> SFR(NAME, 0xNN);          （直接 SFR 页）
    sbit NAME = BASE^n;           基址是 8 的倍数：SBIT(NAME, 0xNN);（位地址 = 基址+n）
                                   否则：退化为 #define NAME 0xMM 掩码
    (*(unsigned char volatile far *)ADDR) -> (*(volatile unsigned char __xdata *)ADDR)
    删除 Keil 专有的 stdio.h/intrins.h 包含、_m/main 宏、文件尾守卫

说明：SDCC 只能对标准可位寻址 SFR（地址为 8 的倍数）做 __sbit；
      STC 扩展的“全 SFR 位寻址”在 SDCC 下必须用掩码 + |= 操作。
"""

import argparse
import re
import sys
from pathlib import Path


def read_text_auto(path: Path) -> str:
    """自动识别源文件编码：优先 UTF-8 严格，否则回退 GBK(936)。"""
    data = path.read_bytes()
    try:
        data.decode("utf-8", errors="strict")
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.decode("gbk", errors="replace")


RE_SFR = re.compile(r"^\s*sfr\s+(\w+)\s*=\s*(0x[0-9A-Fa-f]+)")
RE_SFR_REST = re.compile(r"^\s*sfr\s+(\w+)\s*=\s*(0x[0-9A-Fa-f]+)\s*;(?P<rest>.*)$")
RE_SBIT = re.compile(r"^\s*sbit\s+(\w+)\s*=\s*(\w+)\s*\^\s*(\d+)\s*;(?P<rest>.*)$")
RE_FAR_PTR = re.compile(r"unsigned char volatile far \*")
RE_EAXSFR = re.compile(r"^\s*#define\s+EAXSFR\s*\(\s*\)")
RE_EAXRAM = re.compile(r"^\s*#define\s+EAXRAM\s*\(\s*\)")

SKIP_PATTERNS = [
    re.compile(r"^\s*#ifndef\s+__AI8051U_H__"),
    re.compile(r"^\s*#define\s+__AI8051U_H__"),
    re.compile(r'^\s*#include\s+"(stdio|intrins)\.h"'),
    re.compile(r"^\s*extern\s+void\s+_m\s*\("),
    re.compile(r"^\s*#define\s+main\s*\("),
    re.compile(r"^\s*#endif\s*$"),
]


def translate(input_file: Path, output_file: Path) -> tuple[int, int]:
    text = read_text_auto(input_file)
    lines = re.split(r"\r?\n", text)

    # 第一遍：SFR 名字 -> 字节地址
    sfr_addr: dict[str, int] = {}
    for ln in lines:
        m = RE_SFR.match(ln)
        if m:
            sfr_addr[m.group(1)] = int(m.group(2), 16)

    out: list[str] = []
    out.append("/*")
    out.append(" * ai8051u_sfr.h —— AI8051U（MCS-251 核）SFR / XFR / 位定义（SDCC 版）")
    out.append(" *")
    out.append(" * 由 tools/keil2sdcc.py 从 STC 官方 Keil 头文件自动生成，请勿手改。")
    out.append(f" * 源文件: {input_file.name}")
    out.append(" *")
    out.append(" * 约定：")
    out.append(" *   - 直接 SFR（0x80-0xFF）用 SFR()/SBIT()，定义见 c51.h。")
    out.append(" *   - 扩展 SFR（XFR，0x7E:xxxx）用 __xdata 指针；访问前必须 EAXFR=1。")
    out.append(" *   - 基址不是 8 的倍数的 SFR 位，SDCC 无法位寻址，已退化为掩码 #define，")
    out.append(" *     代码需用 |=、&= 等字节位操作，不能写 NAME = 1。")
    out.append(" */")
    out.append("")
    out.append("#ifndef AI8051U_SFR_H")
    out.append("#define AI8051U_SFR_H")
    out.append("")
    out.append('#include "c51.h"')
    out.append('#include "mcs_intrins.h"')
    out.append('#include <stdio.h>')
    out.append("")
    out.append("/* SDCC <stdio.h> 经 compiler.h 已定义零参数 NOP()，此处解除，改用下面的 NOP(n) */")
    out.append("#undef NOP")
    out.append("")

    mask_count = 0
    sbit_count = 0

    for ln in lines:
        if any(p.search(ln) for p in SKIP_PATTERNS):
            continue

        m = RE_SFR_REST.match(ln)
        if m:
            out.append(f"SFR({m.group(1)}, {m.group(2)});{m.group('rest')}")
            continue

        m = RE_SBIT.match(ln)
        if m:
            name, base, bit_s, rest = m.group(1), m.group(2), int(m.group(3)), m.group("rest")
            if base in sfr_addr and sfr_addr[base] % 8 == 0:
                bit_addr = sfr_addr[base] + bit_s
                out.append(f"SBIT({name}, 0x{bit_addr:02X});{rest}")
                sbit_count += 1
            else:
                mask = 1 << bit_s
                out.append(
                    f"#define {name} 0x{mask:02X}  /* {base}^{bit_s}: 基址非8倍数，SDCC不可位寻址，用掩码 */"
                )
                mask_count += 1
            continue

        if RE_FAR_PTR.search(ln):
            ln = RE_FAR_PTR.sub("volatile unsigned char __xdata *", ln)
            out.append(ln)
            continue

        if RE_EAXSFR.match(ln):
            out.append("#define EAXSFR()  (P_SW2 |= EAXFR)   /* 使能 XFR 访问（SDCC 无位寻址，改字节操作） */")
            continue
        if RE_EAXRAM.match(ln):
            out.append("#define EAXRAM()  (P_SW2 &= ~EAXFR)  /* 恢复 RAM 访问 */")
            continue

        out.append(ln)

    out.append("")
    out.append("#endif /* AI8051U_SFR_H */")

    # 用平台默认行尾（newline=None）：Windows 写 CRLF，POSIX 写 LF。
    # 这样在 Windows 上与原 ps1 输出字节一致；在 Linux/macOS 上符合本地惯例。
    output_file.write_text("\n".join(out) + "\n", encoding="utf-8")
    return sbit_count, mask_count


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input-file", required=True, type=Path)
    ap.add_argument("--output-file", required=True, type=Path)
    args = ap.parse_args()

    if not args.input_file.is_file():
        print(f"error: input file not found: {args.input_file}", file=sys.stderr)
        return 2

    args.output_file.parent.mkdir(parents=True, exist_ok=True)
    sbit_count, mask_count = translate(args.input_file, args.output_file)
    print(
        f"生成 {args.output_file}：{args.output_file.stat().st_size} 字节；"
        f"可位寻址 SBIT {sbit_count} 个，掩码退化 {mask_count} 个"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
