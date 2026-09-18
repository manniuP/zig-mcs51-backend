#!/usr/bin/env python3
"""mcs_cycles.py —— MCS-251（AI8051U）指令周期参考 + ASxxxx 汇编静态周期统计。

**数据来源**：STC《AI8051U 系列》数据手册 **附录A.1.3 指令表（功能排序）**（见
`docs/21-指令周期参考.md`）。表中数值是 **WTST=0、CPU 时钟=1 周期** 时的系统时钟数；
实际总时间：`时钟数 + nrPRGACS*WTST`，访问 XDM 再加 `nrXDMACS*CKCON`（见手册）。

用法：
  python tools/mcs_cycles.py --dump                 # 打印参考表（本后端会用到的形态）
  python tools/mcs_cycles.py --annotate <x.asm>     # 逐条标注周期（含 1/3 条件跳转）
  python tools/mcs_cycles.py --summary  <x.asm>     # 按函数汇总（静态周期、指令数、未识别）

说明：
  - 周期是**静态**计数（分支按形态记 `1/3`）；总周期列取「最小（不跳）/最大（跳）」。
  - `@spx±d`/`@dpx` 归为 251 的 `MOV Rm,@DRk+dis`(0x29)/`@DRk+dis,Rm`(0x39) 形态（1 周期）。
  - `reg,op2` 类（`add spx,#imm`、`inc/dq spx,#short`、`mov dpxl,#`）周期与寻址模式有关，
    手册标注「详见指令详解」，此处按寄存器/立即数形态取 1，并在 `--dump` 里注明。
"""
import argparse
import io
import os
import re
import sys

# ---------------------------------------------------------------------------
# 参考表：本后端 emit 的指令形态 -> (字节, 时钟)
#   形态用操作数类别元组表示，见 classify_operand()
# ---------------------------------------------------------------------------
# 操作数类别：a / rn / dreg / atr / atdreg / imm / dir / bit / rel / x
FORM = {
    # --- 数据传送 ---
    ("mov", "a", "imm"): (2, 1),        # MOV A,#data
    ("mov", "a", "dir"): (2, 1),        # MOV A,dir8（SFR、data 全局）
    ("mov", "a", "rn"): (1, 2),         # MOV A,Rn
    ("mov", "a", "atr"): (1, 2),        # MOV A,@Ri
    ("mov", "a", "atdreg"): (4, 1),     # MOV Rm,@DRk+dis（@spx±d / @dpx）
    ("mov", "rn", "a"): (1, 2),         # MOV Rn,A
    ("mov", "rn", "imm"): (2, 1),       # MOV Rn,#data
    ("mov", "rn", "dir"): (2, 1),       # MOV Rn,dir8
    ("mov", "rn", "atdreg"): (4, 1),    # MOV Rm,@DRk+dis
    ("mov", "dir", "a"): (2, 1),        # MOV dir8,A
    ("mov", "dir", "rn"): (2, 1),       # MOV dir8,Rn
    ("mov", "dir", "imm"): (3, 1),      # MOV dir8,#data
    ("mov", "dir", "dir"): (3, 1),      # MOV dir8,dir8
    ("mov", "atr", "a"): (1, 2),        # MOV @Ri,A
    ("mov", "atr", "imm"): (2, 2),      # MOV @Ri,#data
    ("mov", "atr", "dir"): (2, 2),      # MOV @Ri,dir8
    ("mov", "dir", "atr"): (2, 2),      # MOV dir8,@Ri
    ("xch", "a", "rn"): (1, 2),
    ("xch", "a", "atr"): (1, 2),
    ("xch", "a", "dir"): (2, 1),
    ("xchd", "a", "atr"): (1, 2),
    ("mov", "atdreg", "a"): (4, 1),     # MOV @DRk+dis,Rm（@spx±d,a / @dpx,a）
    ("mov", "atdreg", "rn"): (4, 1),    # MOV @DRk+dis,Rm
    ("mov", "dreg", "imm"): (3, 1),     # MOV DPTR,#data16 / mov dpxl,#（op2 形态取 1）
    ("mov", "dreg", "dreg"): (2, 1),    # MOV DRk,DRk
    ("movx", "a", "atdptr"): (1, 3),    # MOVX A,@DPTR
    ("movx", "atdptr", "a"): (1, 2),    # MOVX @DPTR,A
    ("movx", "a", "atr"): (1, 3),       # MOVX A,@Ri
    ("movx", "atr", "a"): (1, 2),       # MOVX @Ri,A
    ("movc", "a", "x"): (1, 4),         # MOVC A,@A+DPTR（估）/@A+PC=3
    ("movc", "a", "atdreg"): (1, 4),    # MOVC A,@A+DPTR（@a+dptr 归 atdreg）
    ("push", "dir"): (2, 1),
    ("push", "x"): (2, 1),
    ("pop", "dir"): (2, 1),
    ("pop", "x"): (2, 1),
    # --- 算术 ---
    ("add", "a", "rn"): (1, 2),
    ("add", "a", "imm"): (2, 1),
    ("add", "a", "dir"): (2, 1),
    ("add", "a", "atr"): (1, 2),
    ("add", "dreg", "imm"): (4, 1),     # ADD DRk,op2（#data16）op2 形态取 1
    ("add", "dreg", "dreg"): (2, 1),
    ("addc", "a", "rn"): (1, 2),
    ("addc", "a", "imm"): (2, 1),
    ("addc", "a", "dir"): (2, 1),
    ("addc", "a", "atr"): (1, 2),
    ("subb", "a", "rn"): (1, 2),
    ("subb", "a", "imm"): (2, 1),
    ("subb", "a", "dir"): (2, 1),
    ("subb", "a", "atr"): (1, 2),
    ("sub", "dreg", "imm"): (4, 1),
    ("sub", "dreg", "dreg"): (2, 1),
    ("inc", "a", None): (1, 1),
    ("inc", "rn", None): (1, 2),
    ("inc", "dir", None): (2, 1),
    ("inc", "atr", None): (1, 2),
    ("inc", "dreg", "imm"): (2, 1),     # INC reg,#short（op2 形态取 1）
    ("inc", "dreg", None): (1, 1),      # INC DPTR
    ("dec", "a", None): (1, 1),
    ("dec", "rn", None): (1, 2),
    ("dec", "dir", None): (2, 1),
    ("dec", "atr", None): (1, 2),
    ("dec", "dreg", "imm"): (2, 1),
    ("dec", "dreg", None): (1, 1),      # DEC DPTR/DRk（按 1）
    ("mul", "a", "dir"): (1, 1),        # MUL A,B（B 视为 dir）
    ("mul", "rn", "rn"): (2, 1),
    ("div", "a", "dir"): (1, 6),        # DIV A,B
    ("div", "rn", "rn"): (1, 6),
    ("da", "a", None): (1, 3),
    # --- 逻辑 ---
    ("anl", "a", "rn"): (1, 2),
    ("anl", "a", "imm"): (2, 1),
    ("anl", "a", "dir"): (2, 1),
    ("anl", "a", "atr"): (1, 2),
    ("anl", "dir", "a"): (2, 1),
    ("anl", "dir", "imm"): (3, 1),
    ("orl", "a", "rn"): (1, 2),
    ("orl", "a", "imm"): (2, 1),
    ("orl", "a", "dir"): (2, 1),
    ("orl", "a", "atr"): (1, 2),
    ("orl", "dir", "a"): (2, 1),
    ("orl", "dir", "imm"): (3, 1),
    ("xrl", "a", "rn"): (1, 2),
    ("xrl", "a", "imm"): (2, 1),
    ("xrl", "a", "dir"): (2, 1),
    ("xrl", "a", "atr"): (1, 2),
    ("xrl", "dir", "a"): (2, 1),
    ("xrl", "dir", "imm"): (3, 1),
    ("clr", "a", None): (1, 1),
    ("clr", "bit", None): (2, 1),       # CLR C / CLR bit
    ("clr", "x", None): (1, 1),
    ("cpl", "a", None): (1, 1),
    ("cpl", "bit", None): (2, 1),
    ("rl", "a", None): (1, 1),
    ("rlc", "a", None): (1, 1),
    ("rr", "a", None): (1, 1),
    ("rrc", "a", None): (1, 1),
    ("swap", "a", None): (1, 1),
    ("sra", "x", None): (2, 1),
    ("srl", "x", None): (2, 1),
    ("sll", "x", None): (2, 1),
    # --- 布尔 ---
    ("setb", "bit", None): (2, 1),
    ("setb", "dir", None): (2, 1),      # SETB bit（裸位地址按直接位）
    ("setb", "x", None): (2, 1),
    ("clr", "dir", None): (2, 1),       # CLR bit（裸位地址）
    ("cpl", "dir", None): (2, 1),       # CPL bit
    ("anl", "cy", "bit"): (2, 1),
    ("orl", "cy", "bit"): (2, 1),
    ("anl", "bit", "bit"): (2, 1),      # ANL C,bit（cy 归 bit）
    ("orl", "bit", "bit"): (2, 1),      # ORL C,bit
    ("mov", "cy", "bit"): (2, 1),
    ("mov", "bit", "cy"): (2, 1),
    ("mov", "bit", "bit"): (2, 1),      # MOV C,bit / MOV bit,C（cy 归 bit）
    ("mov", "bit", "dir"): (2, 1),      # MOV C,dir（SDAS 位名为 dir）
    ("mov", "dir", "bit"): (2, 1),      # MOV dir,C
    ("movz", "wrj", "rn"): (2, 1),      # MOVZ WRj,Rm
    ("movs", "wrj", "rn"): (2, 1),      # MOVS WRj,Rm
    # --- 控制转移 ---
    ("acall", "rel", None): (2, 3),
    ("lcall", "rel", None): (3, 3),
    ("ecall", "rel", None): (4, 3),
    ("ecall", "atdreg", None): (2, 3),
    ("ret", None, None): (1, 3),
    ("eret", None, None): (1, 3),
    ("reti", None, None): (1, 3),
    ("ajmp", "rel", None): (2, 3),
    ("ljmp", "rel", None): (3, 3),
    ("ejmp", "rel", None): (4, 3),
    ("sjmp", "rel", None): (2, 3),
    ("jmp", "x", None): (1, 3),         # JMP @A+DPTR
    ("jmp", "atdreg", None): (1, 3),    # JMP @A+DPTR（操作数归 atdreg）
    ("trap", None, None): (1, 1),       # Zig trap（软中断/陷阱，取 1）
    ("nop", None, None): (1, 1),
}

# 条件跳转：不跳 / 跳
CONDJMP = {"jz", "jnz", "jc", "jnc", "jsle", "jsg", "jle", "jg",
           "jsl", "jsge", "je", "jne", "jb", "jnb", "jbc"}
# CJNE 形态：(mnem, op1kind, op2kind) -> (bytes, not_taken, taken)
CJNE = {
    ("a", "dir"): (3, 2, 3),
    ("a", "imm"): (3, 1, 3),
    ("rn", "imm"): (3, 3, 4),
    ("atr", "imm"): (3, 3, 4),
}
DJNZ = {
    "rn": (2, 3, 4),
    "dir": (3, 2, 3),
}

def classify_operand(tok):
    """只按操作数本身分类（不依赖助记符；rel 由 operand_kinds 标）。"""
    t = tok.strip().lower()
    if t == "a":
        return "a"
    if t in ("cy", "c"):
        return "bit"
    if t.startswith("#"):
        return "imm"
    if t.startswith("@"):
        base = t.split("+")[0].split("-")[0]
        if base in ("@r0", "@r1"):
            return "atr"
        if base in ("@dptr",):
            return "atdptr"
        return "atdreg"                     # @dpx / @spx±dis / @drk
    if re.fullmatch(r"r[0-7]", t):
        return "rn"
    if re.fullmatch(r"wr\d+", t):
        return "wrj"
    if re.fullmatch(r"dr\d+", t) or t in ("dpx", "spx", "dptr"):
        return "dreg"
    # 位地址：十进制/十六进制 . 位号，或 addr^bit
    if re.fullmatch(r"(0x[0-9a-f]+|\d+)\.[0-7]", t) or "^" in t:
        return "bit"
    if re.fullmatch(r"(0x[0-9a-f]+|\d+|[A-Za-z_.][\w.$+]*(\+[0-9]+)?)", t):
        return "dir"
    return "x"


def operand_kinds(mnem, ops):
    kinds = [classify_operand(o) for o in ops]
    # 跳转/调用/条件跳转的目标操作数在末位，标 rel
    if mnem in ("ajmp", "ljmp", "ejmp", "sjmp", "acall", "lcall", "ecall"):
        if len(ops) == 1:
            kinds[0] = "rel"
    elif mnem in ("jb", "jnb", "jbc", "djnz", "cjne"):
        if len(ops) >= 2:
            kinds[-1] = "rel"
    elif mnem in CONDJMP:
        if len(ops) == 1:
            kinds[0] = "rel"
    return kinds


def split_ops(rest):
    """sdas 操作数以逗号分隔；无逗号时按空白拆（单操作数）。"""
    s = rest.strip()
    if not s:
        return []
    if "," in s:
        return [x.strip() for x in s.split(",") if x.strip()]
    return s.split() if " " in s else [s]


def instr_cycles(mnem, ops):
    """返回 (bytes, cycles, note)；cycles 可为 'a/b'（条件跳转不跳/跳）。"""
    kinds = operand_kinds(mnem, ops)
    k1 = kinds[0] if len(kinds) > 0 else None
    k2 = kinds[1] if len(kinds) > 1 else None

    if mnem in CONDJMP:
        return (2, "1/3", "条件跳转(不跳/跳)")
    if mnem == "cjne":
        b = CJNE.get((k1, k2))
        if b:
            return (b[0], "%d/%d" % (b[1], b[2]), "CJNE(不相等跳)")
    if mnem == "djnz":
        b = DJNZ.get(k1)
        if b:
            return (b[0], "%d/%d" % (b[1], b[2]), "DJNZ(非零跳)")
    for key in ((mnem, k1, k2), (mnem, k1), (mnem, k1, None),
                (mnem, None, None)):
        if key in FORM:
            b, c = FORM[key]
            return (b, str(c), "")
    if mnem in ("push", "pop"):
        return (2, 1, "PUSH/POP op2 形态(取 1)")
    return (None, "?", "未识别")


# ---------------------------------------------------------------------------
# 汇编解析
# ---------------------------------------------------------------------------
DIRECTIVE = re.compile(r"^\s*\.")
LABEL = re.compile(r"^([A-Za-z_][\w]*):")
CODE = re.compile(r"^\s+([a-z][a-z0-9]*)\s*(.*)$")


def strip_comment(line):
    i = line.find(";")
    return line[:i] if i >= 0 else line


def iter_instr(path):
    """产出 (func, lineno, mnem, ops_raw, cycles, note, bytes)。"""
    func = "?"
    funcs = {}
    for no, raw in enumerate(io.open(path, encoding="utf-8", errors="replace"), 1):
        line = strip_comment(raw).rstrip("\n")
        if not line.strip():
            continue
        if DIRECTIVE.match(line):
            continue
        if re.match(r"^\s*\w+\s*=", line):      # SDAS 伪赋值（arN = .. 等）
            continue
        m = LABEL.match(line)
        if m:
            name = m.group(1)
            func = name if name.startswith("_") else func
            yield (func, no, None, "", None, "", None)
            continue
        m = CODE.match(line)
        if not m:
            continue
        mnem = m.group(1).lower()
        ops = split_ops(m.group(2))
        b, c, note = instr_cycles(mnem, ops)
        yield (func, no, mnem, " ".join(ops), c, note, b)


def cmd_dump():
    print("参考表（AI8051U / MCS-251，WTST=0；来源：手册 附录A.1.3）")
    print("%-28s %5s %7s  %s" % ("形态", "字节", "时钟", "备注"))
    for (mnem, k1, k2), (b, c) in sorted(FORM.items(), key=lambda x: str(x[0])):
        form = mnem + " " + ",".join(k for k in (k1, k2) if k)
        print("%-28s %5s %7s" % (form, b, c))
    for m in sorted(CONDJMP):
        print("%-28s %5s %7s  条件跳转(不跳/跳)" % (m, 2, "1/3"))
    for (k1, k2), (b, a, c) in sorted(CJNE.items()):
        print("%-28s %5s %7s  CJNE" % ("cjne %s,%s" % (k1, k2), b, "%d/%d" % (a, c)))
    for k, (b, a, c) in sorted(DJNZ.items()):
        print("%-28s %5s %7s  DJNZ" % ("djnz %s" % k, b, "%d/%d" % (a, c)))


def load(path):
    out = []
    for (func, no, mnem, ops, c, note, b) in iter_instr(path):
        if mnem is not None:
            out.append((func, no, mnem, ops, c, note, b))
    return out


def cmd_annotate(path):
    cur = None
    tot_min = tot_max = 0
    for (func, no, mnem, ops, c, note, b) in load(path):
        if func != cur:
            if cur is not None:
                print("-- %s: min=%d max=%d" % (cur, fmin, fmax))
            cur = func
            fmin = fmax = 0
            print("\n[%s]" % func)
        cost = c if c and c != "?" else "0"
        parts = str(cost).split("/")
        lo = int(parts[0]) if parts[0].isdigit() else 0
        hi = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else lo
        fmin += lo
        fmax += hi
        tot_min += lo
        tot_max += hi
        print("  %5d  %-22s %4s %6s   %s" % (no, mnem + " " + ops, c, b or "-",
                                              note))
    if cur is not None:
        print("-- %s: min=%d max=%d" % (cur, fmin, fmax))
    print("\n静态合计：min=%d max=%d（分支按 1/3 计）" % (tot_min, tot_max))


def cmd_summary(path):
    funcs = {}
    unknown = {}
    for (func, no, mnem, ops, c, note, b) in load(path):
        d = funcs.setdefault(func, {"n": 0, "min": 0, "max": 0, "mn": {}})
        parts = str(c).split("/") if c and c != "?" else ["0"]
        lo = int(parts[0]) if parts[0].isdigit() else 0
        hi = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else lo
        d["n"] += 1
        d["min"] += lo
        d["max"] += hi
        d["mn"][mnem] = d["mn"].get(mnem, 0) + 1
        if c == "?":
            unknown[(mnem, ops)] = unknown.get((mnem, ops), 0) + 1
    print("%-24s %6s %8s %8s" % ("函数", "指令", "min周期", "max周期"))
    for f, d in sorted(funcs.items()):
        print("%-24s %6d %8d %8d" % (f, d["n"], d["min"], d["max"]))
    if unknown:
        print("\n未识别指令（请补 FORM）：")
        for (mnem, ops), n in sorted(unknown.items()):
            print("  %4d  %s %s" % (n, mnem, ops))


def cmd_range(path, a, b, taken):
    """打印 [a,b] 行号内的指令并汇总周期；--taken 时条件分支按「跳」计。"""
    tot = 0
    n = 0
    for (func, no, mnem, ops, c, note, by) in load(path):
        if no < a or no > b:
            continue
        if not c or c == "?":
            cost = 0
        elif "/" in c:
            cost = int(c.split("/")[1 if taken else 0])
        else:
            cost = int(c)
        tot += cost
        n += 1
        print("%5d  %-24s %6s -> %d" % (no, mnem + " " + ops, c, cost))
    print("\n[%d,%d] 共 %d 条，周期=%d%s" % (a, b, n, tot,
          "（条件分支按跳计）" if taken else ""))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("asm", nargs="?", help="ASxxxx 汇编文件")
    ap.add_argument("--dump", action="store_true", help="打印参考表")
    ap.add_argument("--annotate", action="store_true", help="逐条标注周期")
    ap.add_argument("--summary", action="store_true", help="按函数汇总")
    ap.add_argument("--range", nargs=2, type=int, metavar=("A", "B"),
                    help="只汇总 A..B 行（配合 --taken）")
    ap.add_argument("--taken", action="store_true", help="条件分支按「跳」计")
    args = ap.parse_args()

    if args.dump or not args.asm:
        cmd_dump()
        return 0
    if args.range:
        cmd_range(args.asm, args.range[0], args.range[1], args.taken)
    elif args.annotate:
        cmd_annotate(args.asm)
    elif args.summary:
        cmd_summary(args.asm)
    else:
        cmd_summary(args.asm)
    return 0


if __name__ == "__main__":
    sys.exit(main())
