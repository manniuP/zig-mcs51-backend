#!/usr/bin/env python3
"""把 STC Keil HAL 的 C 源码批量翻译为 SDCC 可用形式。

用法：
    python tools/keil2sdcc_c.py \\
        --input-dir tools/vendor/stc/hal \\
        --output-dir lib/stc-hal \\
        --sfr-header tools/vendor/stc/AI8051U.keil.h

规则（只改代码部分，不动 // 与 /* */ 注释）：
    void f(void) interrupt N        -> void f(void) __interrupt(N)
    sbit NAME = PORT^n;             -> __sbit __at(位地址) NAME;   （位地址 = PORT 地址 + n）
    sfr  NAME = 0xNN;               -> __sfr __at(0xNN) NAME;
    typedef bit / bit / xdata / ... -> SDCC 关键字（__bit / __xdata / ...）
    #include "ai8051u.h"            -> #include "ai8051u_sfr.h"
    #include "intrins.h"           -> #include "mcs_intrins.h"
    Keil char putchar(char)         -> SDCC int putchar(int)

不翻译 AI8051U.H（已由 keil2sdcc.py 生成 lib/include/ai8051u_sfr.h）。
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


def load_sfr_addr(sfr_header: Path) -> dict[str, int]:
    sfr_addr: dict[str, int] = {}
    if not sfr_header.is_file():
        return sfr_addr
    for ln in re.split(r"\r?\n", read_text_auto(sfr_header)):
        m = re.match(r"^\s*sfr\s+(\w+)\s*=\s*(0x[0-9A-Fa-f]+)", ln)
        if m:
            sfr_addr[m.group(1)] = int(m.group(2), 16)
    return sfr_addr


def load_degraded(sfr_header: Path, sfr_addr: dict[str, int]) -> dict[str, dict[str, object]]:
    """非可位寻址 SFR 的位：name -> {base, mask}。"""
    degraded: dict[str, dict[str, object]] = {}
    if not sfr_header.is_file():
        return degraded
    for ln in re.split(r"\r?\n", read_text_auto(sfr_header)):
        m = re.match(r"^\s*sbit\s+(\w+)\s*=\s*(\w+)\s*\^\s*(\d+)", ln)
        if not m:
            continue
        name, base, bit = m.group(1), m.group(2), int(m.group(3))
        if base in sfr_addr and sfr_addr[base] % 8 != 0:
            degraded[name] = {"base": base, "mask": 1 << bit}
    return degraded


def split_code_comment(line: str, in_block: list[bool]) -> tuple[str, str]:
    """把一行拆成“代码”和“注释”，保持字符串/字符/块注释状态。

    `in_block` 是单元素列表，用于跨行传递块注释状态（模拟 PowerShell 的 [ref]）。
    """
    code: list[str] = []
    cmt: list[str] = []
    i, n = 0, len(line)
    in_str = False
    in_chr = False

    while i < n:
        ch = line[i]
        if in_block[0]:
            if i + 1 < n and ch == "*" and line[i + 1] == "/":
                in_block[0] = False
                cmt.append("*/")
                i += 2
                continue
            cmt.append(ch)
            i += 1
            continue
        if in_str or in_chr:
            code.append(ch)
            if ch == "\\":
                if i + 1 < n:
                    code.append(line[i + 1])
                    i += 2
                    continue
            elif (in_str and ch == '"') or (in_chr and ch == "'"):
                in_str = False
                in_chr = False
            i += 1
            continue
        if i + 1 < n and ch == "/" and line[i + 1] == "/":
            cmt.append(line[i:])
            break
        if i + 1 < n and ch == "/" and line[i + 1] == "*":
            in_block[0] = True
            cmt.append("/*")
            i += 2
            continue
        if ch == '"':
            in_str = True
            code.append('"')
            i += 1
            continue
        if ch == "'":
            in_chr = True
            code.append("'")
            i += 1
            continue
        code.append(ch)
        i += 1

    return "".join(code), "".join(cmt)


class CodeTranslator:
    def __init__(self, sfr_addr: dict[str, int], degraded: dict[str, dict[str, object]]):
        self.sfr_addr = sfr_addr
        self.degraded = degraded
        self.warnings: list[str] = []
        if degraded:
            alt = "|".join(
                re.escape(name) for name in sorted(degraded.keys(), key=len, reverse=True)
            )
            self._deg_alt = alt
        else:
            self._deg_alt = ""

    def _sbit_repl(self, m: re.Match) -> str:
        name, base, bit = m.group(1), m.group(2), int(m.group(3))
        if base in self.sfr_addr:
            bit_addr = self.sfr_addr[base] + bit
            return f"__sbit __at(0x{bit_addr:02X}) {name};"
        self.warnings.append(f"未知 sbit 基址: {base} （{name}）")
        return m.group(0)

    def _deg_set_one(self, m: re.Match) -> str:
        d = self.degraded[m.group(1)]
        return f"{d['base']} |= 0x{d['mask']:02X};"

    def _deg_set_zero(self, m: re.Match) -> str:
        d = self.degraded[m.group(1)]
        return f"{d['base']} &= ~0x{d['mask']:02X};"

    def _deg_set_expr(self, m: re.Match) -> str:
        d = self.degraded[m.group(1)]
        return (
            f"{d['base']} = (unsigned char)(({d['base']} & ~0x{d['mask']:02X}) "
            f"| (({m.group(2)}) ? 0x{d['mask']:02X} : 0))"
        )

    def _deg_read(self, m: re.Match) -> str:
        d = self.degraded[m.group(1)]
        return f"({d['base']} & 0x{d['mask']:02X})"

    def translate(self, code: str) -> str:
        # STC 头：兼容 "ai8051u.h"、"../comm/AI8051U.H"、<intrins.h> 等写法。
        code = re.sub(
            r'(?i)#\s*include\s*["<][^">]*AI8051U\.H[">]',
            '#include "ai8051u_sfr.h"',
            code,
        )
        code = re.sub(
            r'(?i)#\s*include\s*[<"]intrins\.h[>"]',
            '#include "mcs_intrins.h"',
            code,
        )
        # 中断函数：void f(void) interrupt N  ->  void f(void) __interrupt(N)
        code = re.sub(r"(\)\s*)interrupt\s+([A-Za-z_]\w*|\d+)", r"\g<1>__interrupt(\g<2>)", code)
        code = re.sub(r"\bsfr\s+(\w+)\s*=\s*(0x[0-9A-Fa-f]+)\s*;", r"__sfr __at(\g<2>) \g<1>;", code)
        # sbit 展开为位地址
        code = re.sub(
            r"\bsbit\s+(\w+)\s*=\s*(\w+)\s*\^\s*(\d+)\s*;",
            self._sbit_repl,
            code,
        )

        # 非可位寻址 SFR 位的读写改写为字节操作
        if self._deg_alt:
            code = re.sub(
                r"\b(" + self._deg_alt + r")\s*=\s*1\s*;",
                self._deg_set_one,
                code,
            )
            code = re.sub(
                r"\b(" + self._deg_alt + r")\s*=\s*0\s*;",
                self._deg_set_zero,
                code,
            )
            # PowerShell 原版用 (?=[;:)]|$)，Python re 的 $ 在多行模式是字符串末尾；
            # 这里始终处理单行 code 片段（不含换行），用 \Z 保证语义一致。
            code = re.sub(
                r"\b(" + self._deg_alt + r")\s*=(?!=)\s*([^;:?()]+?)\s*(?=[;:)]|\Z)",
                self._deg_set_expr,
                code,
            )
            code = re.sub(r"\b(" + self._deg_alt + r")\b", self._deg_read, code)

        # 类型限定符与关键字
        code = re.sub(r"\btypedef\s+bit\b", "typedef __bit", code)
        # 注意：PowerShell -replace 默认大小写不敏感，会把宏 BIT(b) 也替换为 __bit(b)。
        # 这里复制原行为以保持输出字节一致（已知行为，不修正）。
        code = re.sub(r"\bbit\b", "__bit", code, flags=re.IGNORECASE)
        code = re.sub(r"\bxdata\b", "__xdata", code)
        code = re.sub(r"\bedata\b", "__xdata", code)
        code = re.sub(r"\bbdata\b", "__data", code)
        code = re.sub(r"\bidata\b", "__idata", code)
        code = re.sub(r"\bpdata\b", "__pdata", code)
        code = re.sub(r"\bcode\b", "__code", code)
        code = re.sub(r"\bfar\b", "__far", code)
        code = re.sub(r"\bnear\b", "__near", code)
        code = re.sub(r"\bdata\b", "__data", code)
        code = re.sub(r"\breentrant\b", "__reentrant", code)
        # Keil 的 putchar 为 char(char)，SDCC stdio 要求 int(int)
        code = re.sub(r"\bchar\s+putchar\b", "int putchar", code)
        code = re.sub(r"(putchar\s*\(\s*)char\b", r"\g<1>int", code)
        return code


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input-dir", required=True, type=Path)
    ap.add_argument("--output-dir", required=True, type=Path)
    ap.add_argument("--sfr-header", type=Path, default=Path("tools/vendor/stc/AI8051U.keil.h"))
    args = ap.parse_args()

    if not args.input_dir.is_dir():
        print(f"error: input dir not found: {args.input_dir}", file=sys.stderr)
        return 2

    sfr_addr = load_sfr_addr(args.sfr_header)
    degraded = load_degraded(args.sfr_header, sfr_addr)
    translator = CodeTranslator(sfr_addr, degraded)

    args.output_dir.mkdir(parents=True, exist_ok=True)

    files = [
        p
        for p in args.input_dir.iterdir()
        if p.is_file()
        and p.suffix.lower() in (".c", ".h")
        and p.name.upper() != "AI8051U.H"
    ]

    for f in files:
        text = read_text_auto(f)
        lines = re.split(r"\r?\n", text)
        in_block = [False]
        result = []
        for ln in lines:
            code, cmt = split_code_comment(ln, in_block)
            result.append(translator.translate(code) + cmt)
        out_path = args.output_dir / f.name
        out_path.write_text("\n".join(result) + "\n", encoding="utf-8")
        print(f"翻译 {f.name}")

    if translator.warnings:
        print("警告：")
        for w in sorted(set(translator.warnings)):
            print(f"  {w}")
    print(f"完成：{len(files)} 个文件 -> {args.output_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
