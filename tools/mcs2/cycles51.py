#!/usr/bin/env python3
"""8051（8 位模式）指令周期参考 + 汇编静态周期统计。

用途：把 mcs2 / SDCC / Keil 三方生成的 8051 汇编，用同一张表折算成「估算周期」，
做同一段代码的横向比较（三家都是经典 8051 操作码，可以用同一张表）。

口径（经典 8051 机器周期，12T；AI8051U 是 1T 核，绝对时间乘 12/Fosc，相对比较不受影响）：
  - 条件跳转记 1/2（不跳/跳）；总周期给「最小（都不跳）」与「最大（都跳）」两列。
  - 调用按 lcall(2) 计，不含被调方（与函数体字节数口径一致）。
  - 未识别指令计入 unknown，不参与求和并打印出来，方便补表。

数据来源：STC《AI8051U 系列》手册「指令表」（8 位模式与经典 8051 一致）；
在线手册：https://help.stcaimcu.com/mcp
交叉核对：mcs251/tools/mcs_cycles.py（251 模式同一手册附录 A.1.3）

用法：python tools/mcs2/cycles51.py --summary <file.asm|.lst>
"""
from __future__ import annotations

import argparse
import re
import sys

CYCLE = {
    ("nop", ()): 1,
    ("mov", ("a", "imm")): 1, ("mov", ("a", "dir")): 1, ("mov", ("a", "rn")): 1,
    ("mov", ("a", "atri")): 1, ("mov", ("a", "atdptr")): 2, ("mov", ("a", "atadptr")): 2,
    ("mov", ("rn", "a")): 1, ("mov", ("rn", "imm")): 1, ("mov", ("rn", "dir")): 2,
    ("mov", ("dir", "a")): 1, ("mov", ("dir", "rn")): 2, ("mov", ("dir", "dir")): 2,
    ("mov", ("dir", "imm")): 2, ("mov", ("dir", "atdptr")): 2,
    ("mov", ("atri", "a")): 1, ("mov", ("atri", "dir")): 2, ("mov", ("atri", "imm")): 1,
    ("mov", ("atdptr", "a")): 2, ("mov", ("atadptr", "a")): 2,
    ("mov", ("dptr", "imm")): 2,
    ("movc", ("a", "atadptr")): 2, ("movc", ("a", "atapc")): 2,
    ("movx", ("a", "atdptr")): 2, ("movx", ("atdptr", "a")): 2,
    ("push", ("dir",)): 2, ("pop", ("dir",)): 2,
    ("xch", ("a", "dir")): 1, ("xch", ("a", "rn")): 1, ("xch", ("a", "atri")): 1,
    ("xchd", ("a", "atri")): 1,
    ("add", ("a", "imm")): 1, ("add", ("a", "dir")): 1, ("add", ("a", "rn")): 1,
    ("add", ("a", "atri")): 1,
    ("addc", ("a", "imm")): 1, ("addc", ("a", "dir")): 1, ("addc", ("a", "rn")): 1,
    ("addc", ("a", "atri")): 1,
    ("subb", ("a", "imm")): 1, ("subb", ("a", "dir")): 1, ("subb", ("a", "rn")): 1,
    ("subb", ("a", "atri")): 1,
    ("inc", ("a",)): 1, ("inc", ("rn",)): 1, ("inc", ("dir",)): 1, ("inc", ("atri",)): 1,
    ("inc", ("dptr",)): 2,
    ("dec", ("a",)): 1, ("dec", ("rn",)): 1, ("dec", ("dir",)): 1, ("dec", ("atri",)): 1,
    ("mul", ("ab",)): 4,
    ("div", ("ab",)): 4,
    ("da", ("a",)): 1,
    ("anl", ("a", "imm")): 1, ("anl", ("a", "dir")): 1, ("anl", ("a", "rn")): 1,
    ("anl", ("a", "atri")): 1, ("anl", ("dir", "a")): 1, ("anl", ("dir", "imm")): 2,
    ("orl", ("a", "imm")): 1, ("orl", ("a", "dir")): 1, ("orl", ("a", "rn")): 1,
    ("orl", ("a", "atri")): 1, ("orl", ("dir", "a")): 1, ("orl", ("dir", "imm")): 2,
    ("xrl", ("a", "imm")): 1, ("xrl", ("a", "dir")): 1, ("xrl", ("a", "rn")): 1,
    ("xrl", ("a", "atri")): 1, ("xrl", ("dir", "a")): 1, ("xrl", ("dir", "imm")): 2,
    ("clr", ("a",)): 1, ("clr", ("c",)): 1, ("clr", ("bit",)): 1,
    ("cpl", ("a",)): 1, ("cpl", ("c",)): 1, ("cpl", ("bit",)): 1,
    ("setb", ("c",)): 1, ("setb", ("bit",)): 1,
    ("rl", ("a",)): 1, ("rr", ("a",)): 1, ("rlc", ("a",)): 1, ("rrc", ("a",)): 1,
    ("swap", ("a",)): 1,
    ("sjmp", ("rel",)): 2, ("ajmp", ("rel",)): 2, ("ljmp", ("rel",)): 3,
    ("acall", ("rel",)): 2, ("lcall", ("rel",)): 2,
    ("ret", ()): 2, ("reti", ()): 2,
    ("jmp", ("atadptr",)): 2,
    ("jc", ("rel",)): (1, 2), ("jnc", ("rel",)): (1, 2),
    ("jz", ("rel",)): (1, 2), ("jnz", ("rel",)): (1, 2),
    ("jb", ("bit", "rel")): (1, 2), ("jnb", ("bit", "rel")): (1, 2),
    ("jbc", ("bit", "rel")): (1, 2),
    ("cjne", ("a", "imm", "rel")): (1, 2), ("cjne", ("a", "dir", "rel")): (1, 2),
    ("cjne", ("rn", "imm", "rel")): (1, 2), ("cjne", ("atri", "imm", "rel")): (1, 2),
    ("djnz", ("rn", "rel")): (2, 2), ("djnz", ("dir", "rel")): (2, 2),
}

RE_LABEL = re.compile(r"^\s*([A-Za-z_.$?][\w.$?]*):")
RE_INSN = re.compile(r"^\s*([A-Za-z]+)\b\s*(.*)$")
RE_KEIL = re.compile(r"^([0-9A-Fa-f]{4})\s+(?:[0-9A-Fa-f]{2,8}\s+)+(\S+)\s*(.*)$")


def classify(operands: str) -> tuple:
    ops = [o.strip() for o in operands.split(",") if o.strip()]
    out = []
    for o in ops:
        low = o.lower()
        if low == "a":
            out.append("a")
        elif low == "ab":
            out.append("ab")
        elif low == "c":
            out.append("c")
        elif low == "dptr":
            out.append("dptr")
        elif re.fullmatch(r"r[0-7]", low):
            out.append("rn")
        elif low in ("@r0", "@r1"):
            out.append("atri")
        elif low == "@dptr":
            out.append("atdptr")
        elif low in ("@a+dptr", "@a+pc"):
            out.append("atadptr" if "dptr" in low else "atapc")
        elif low.startswith("#"):
            out.append("imm")
        elif low.startswith("/"):
            out.append("bit")
        else:
            out.append("dir")
    return tuple(out)


def cycles_of(mnemonic: str, ops: tuple):
    key = (mnemonic, ops)
    if key in CYCLE:
        v = CYCLE[key]
        return v if isinstance(v, tuple) else (v, v)
    if ops and ops[-1] == "dir":
        k2 = (mnemonic, ops[:-1] + ("bit",))
        if k2 in CYCLE:
            v = CYCLE[k2]
            return v if isinstance(v, tuple) else (v, v)
    return None


def summarize(path) -> dict:
    from pathlib import Path

    text = Path(path).read_text(encoding="utf-8", errors="replace")
    insns = 0
    lo = hi = 0
    unknown = []
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith(";"):
            continue
        line = RE_LABEL.sub("", line)
        m = RE_KEIL.match(line)
        if m:
            mnem, rest = m.group(2), m.group(3)
        else:
            m2 = RE_INSN.match(line)
            if not m2:
                continue
            mnem, rest = m2.group(1), m2.group(2)
        mnem = mnem.lower()
        rest = rest.split(";")[0].strip()
        ops = () if not rest else classify(rest)
        if ops and (mnem.startswith("j") or mnem in ("cjne", "djnz")):
            ops = tuple("rel" if i == len(ops) - 1 else o for i, o in enumerate(ops))
        cyc = cycles_of(mnem, ops)
        if cyc is None:
            unknown.append((mnem + " " + rest).strip())
            continue
        insns += 1
        lo += cyc[0]
        hi += cyc[1]
    return {"insns": insns, "min": lo, "max": hi, "unknown": unknown}




def _slice_fn(text: str, label: str, style: str) -> list[str]:
    """把某个函数的汇编行切出来（含首尾）。style: asm | keil。"""
    lines = text.splitlines()
    out = []
    started = False
    if style == "keil":
        begin = "; FUNCTION " + label + " (BEGIN)"
        end = "; FUNCTION " + label + " (END)"
        for line in lines:
            if not started:
                if begin in line:
                    started = True
                continue
            if end in line:
                break
            out.append(line)
        return out
    for line in lines:
        if not started:
            m = re.match(r"^_?" + re.escape(label) + r":", line)
            if m:
                started = True
            continue
        out.append(line)
        s = line.strip().lower()
        if s == "ret" or s.startswith("ret ") or s == "reti" or s.startswith("reti "):
            break
    return out


def fn_cycles(text: str, label: str, style: str = "asm") -> dict:
    body = _slice_fn(text, label, style)
    insns = 0
    lo = hi = 0
    unknown = []
    for line in body:
        if not line.strip() or line.lstrip().startswith(";"):
            continue
        line = RE_LABEL.sub("", line)
        m = RE_KEIL.match(line)
        if m:
            mnem, rest = m.group(2), m.group(3)
        else:
            m2 = RE_INSN.match(line)
            if not m2:
                continue
            mnem, rest = m2.group(1), m2.group(2)
        mnem = mnem.lower()
        rest = rest.split(";")[0].strip()
        ops = () if not rest else classify(rest)
        if ops and (mnem.startswith("j") or mnem in ("cjne", "djnz")):
            ops = tuple("rel" if i == len(ops) - 1 else o for i, o in enumerate(ops))
        cyc = cycles_of(mnem, ops)
        if cyc is None:
            unknown.append((mnem + " " + rest).strip())
            continue
        insns += 1
        lo += cyc[0]
        hi += cyc[1]
    return {"insns": insns, "min": lo, "max": hi, "unknown": unknown}



ROW = re.compile(r"^\s*([0-9A-Fa-f]{4,6})\s+\S.*?\[\s*\d+\]\s+\d+\s+(.*)$")


def _count(lines) -> dict:
    insns = 0
    lo = hi = 0
    unknown = []
    for line in lines:
        if not line.strip() or line.lstrip().startswith(";"):
            continue
        line = RE_LABEL.sub("", line)
        m = RE_KEIL.match(line)
        if m:
            mnem, rest = m.group(2), m.group(3)
        else:
            m2 = RE_INSN.match(line)
            if not m2:
                continue
            mnem, rest = m2.group(1), m2.group(2)
        mnem = mnem.lower()
        rest = rest.split(";")[0].strip()
        ops = () if not rest else classify(rest)
        if ops and (mnem.startswith("j") or mnem in ("cjne", "djnz")):
            ops = tuple("rel" if i == len(ops) - 1 else o for i, o in enumerate(ops))
        cyc = cycles_of(mnem, ops)
        if cyc is None:
            unknown.append((mnem + " " + rest).strip())
            continue
        insns += 1
        lo += cyc[0]
        hi += cyc[1]
    return {"insns": insns, "min": lo, "max": hi, "unknown": unknown}


def fn_cycles_lst(text: str, label: str) -> dict:
    """从 asxxxx 风格的 .lst 里切一个函数（首指令 → RET），与 fnsize 口径一致。
    找不到给定 label 时退化成「第一个后面紧跟指令行的符号」。"""
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if re.match(r"^\s*_?" + re.escape(label) + r":\s*$", line):
            start = i
            break
    if start is None:
        for i, line in enumerate(lines):
            if re.match(r"^\s*_[A-Za-z0-9_]+:\s*$", line) and i + 1 < len(lines) and ROW.match(lines[i + 1]):
                start = i
                break
    if start is None:
        return {"insns": 0, "min": 0, "max": 0, "unknown": []}
    body = []
    for line in lines[start + 1:]:
        m = ROW.match(line)
        if not m:
            continue
        txt = m.group(2).strip()
        body.append(txt)
        up = txt.upper()
        if up.startswith("RET"):
            break
    return _count(body)

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--summary", metavar="FILE")
    args = ap.parse_args()
    if not args.summary:
        ap.print_help()
        return 2
    r = summarize(args.summary)
    print("指令 %d 条；周期 %d-%d；未识别 %d" % (r["insns"], r["min"], r["max"], len(r["unknown"])))
    for u in r["unknown"][:10]:
        print("  ?", u)
    return 0


if __name__ == "__main__":
    sys.exit(main())