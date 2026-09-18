#!/usr/bin/env python3
"""MCS 后端汇编（ASxxxx 文本）局部优化工具 —— 独立运行，**无需重编 zig**。

背景（见 `docs/06`、`docs/交接-2026-09-15.md` §5.10）：
    MCS 后端为每个内联调用点各生成一份代码，且喜欢「先把值写进 SPX 帧槽、
    再读回来」；再加上 `inc/dec spx` 只能以 1/2/4 为步长，prologue/epilogue
    会展开成一长串 `inc spx,#0x04`。`sdld` 又不回收未用段，代码很容易顶满
    64KB Flash。重编 `zig.exe` 很慢，所以把「瘦身」做成**构建后处理工具**。

本工具在 `fix_mcs_labels.py` 之后、`sdas*` 之前对 `.asm` 做局部、可证明安全的
改写（只在基本块内、不跨标签/分支/调用）：

  R1 合并连续同向的 `inc/dec spx` 调整：
        inc spx,#0x04 × 17   ->   add spx,#0x0044
     （`inc WRj,#short` 只允许 1/2/4，故原来只能展开；`add/sub spx,#imm16` 一次搞定。）

  R2 直块内值编号，删除冗余 `mov`：
        mov a,@spx-0x4 ; mov r0,a ; mov a,@spx-0x4   ->   第三条删掉
     模型：每个已知位置的「值令牌」相同即代表两个位置当前相等；任何写入（含未知
     指令）都换新令牌；遇到标签/指令边界/分支/调用即清空。

  R3 `mov a,X` 紧跟 `mov Y,a`（且 a 随后被覆盖）-> `mov Y,X`：
        mov a,dpl ; mov @spx-0x4,a   ->   mov @spx-0x4,dpl
     `mov Y,X` 形式必须为 sdas 认可的组合（见 `_can_mov`）。

  R4 A 为编译期常量时，`mov a,#C ; mov Y,a` -> `mov Y,#C`（省「载入 A 再转存」）。

  R5 回收无用代码/跳转：
      R5a `ejmp L` 紧跟 `L:`（跳到下一行）= 空操作 -> 删掉跳转；
      R5b 无条件转移（`ejmp/ljmp/sjmp/ajmp/jmp/ret/reti/eret`）之后、下一个标签
          之前的指令不可达 -> 删掉（遇标签/指令边界即恢复可达）。

用法：
    python mcs_opt.py <file.asm>              # 就地改写
    python mcs_opt.py <in.asm> -o <out.asm>   # 输出到别处
    python mcs_opt.py <file.asm> --stats      # 打印各规则命中次数与指令数变化
    python mcs_opt.py --self-test             # 内置回归用例（R1~R5）
    python mcs_opt.py <file.asm> --no-r5      # 关闭某条规则（r1..r5）

注意：仅处理 `mov`/`inc`/`dec`/`push`/`pop` 等已建模指令；未知指令一律当作
「清空状态」的屏障处理，宁可少优化也不改语义。
"""

import argparse
import re
import sys
from pathlib import Path

# 标签：`name:`（可带缩进与否）。
LABEL_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*):")
# 指令：可缩进的助记符 + 可选操作数。
INSN_RE = re.compile(r"^\s+([A-Za-z][A-Za-z0-9_]*)\b\s*(.*)$")
# `@spx` / `@spx-0x1` / `@spx+0x2`。
MEMSTACK_RE = re.compile(r"^@spx(?:(?P<sign>[+-])0x(?P<off>[0-9a-fA-F]+))?$")

# 8 位可 mov 寄存器（SS 的 byte register 或 R0-R7）。
REG8 = {"a", "b", "dpl", "dph", "dpxl"}
REG8_RE = re.compile(r"^r[0-7]$")

# 会写第 1 个操作数（寄存器）的指令族。
WRITE_DEST = {
    "add", "addc", "sub", "subb", "anl", "orl", "xrl",
    "inc", "dec", "clr", "cpl", "rl", "rlc", "rr", "rrc",
    "sra", "srl", "sll", "swap", "da", "movx", "movc",
}
# 改变控制流 / 读 A 无法精细建模 -> 清空全部状态。
RESET = {
    "ajmp", "ejmp", "ljmp", "sjmp", "jmp", "jc", "jnc", "jz", "jnz",
    "je", "jne", "jg", "jle", "jsl", "jsle", "jsg", "jsge",
    "jbc", "jb", "jnb", "cjne", "djnz", "acall", "ecall", "lcall",
    "ret", "reti", "eret", "trap", "esc", "setb",
}
# 一次写 A 与 B。
WRITE_AB = {"mul", "div"}

# 无条件控制转移：其后到下一个标签之间的指令不可达。
UNCOND_STOP = {"ejmp", "ljmp", "sjmp", "ajmp", "jmp", "ret", "reti", "eret"}
# 其中的无条件跳转（可判断「跳到紧随其后的标签」= 空操作）。
UNCOND_JUMP = {"ejmp", "ljmp", "sjmp", "ajmp", "jmp"}


def _norm_reg(op: str) -> str:
    op = op.strip().lower()
    if op == "acc":
        return "a"
    return op


def _canon_memstack(op: str):
    """把 `@spx-0x0` 规范成 `@spx`；返回规范串或 None。"""
    m = MEMSTACK_RE.match(op.strip().lower())
    if not m:
        return None
    off = int(m.group("off"), 16) if m.group("off") else 0
    if m.group("sign") == "-":
        off = -off
    if off == 0:
        return "@spx"
    return f"@spx{off:+d}"


def _canon_loc(op: str):
    """若操作数是可跟踪的单字节位置，返回规范名；否则 None。"""
    op = op.strip().lower()
    if op == "acc":
        op = "a"
    ms = _canon_memstack(op)
    if ms is not None:
        return ms
    if op in REG8 or REG8_RE.match(op):
        return op
    return None


def _is_imm(op: str) -> bool:
    return op.strip().startswith("#")


def _can_mov(dst: str, src: str) -> bool:
    """判断 `mov dst,src` 是否为 sdas251 认可的 8 位形式（实测自 as251）。"""
    dst = _norm_reg(dst)
    src = _norm_reg(src)
    dst_reg = dst in REG8 or bool(REG8_RE.match(dst))
    src_reg = src in REG8 or bool(REG8_RE.match(src))
    dst_ms = _canon_memstack(dst) is not None
    src_ms = _canon_memstack(src) is not None
    if dst_reg:
        if src_reg or _is_imm(src):
            return True
        if src_ms:
            # `mov a,@spx` / `mov rN,@spx` 可以；`mov dpl,@spx` 不行。
            return dst == "a" or bool(REG8_RE.match(dst))
        return False
    if dst_ms:
        # `mov @spx,rN` / `mov @spx,a` 可以；`mov @spx,dpl`、`mov @spx,#imm` 不行。
        return src == "a" or bool(REG8_RE.match(src))
    return False


def _split_operands(rest: str):
    rest = rest.strip()
    if not rest:
        return []
    return [x.strip() for x in rest.split(",")]


class Entry:
    __slots__ = ("kind", "raw", "mnem", "ops", "label")

    def __init__(self, kind, raw, mnem="", ops=None, label=""):
        self.kind = kind  # "insn" | "label" | "directive" | "blank"
        self.raw = raw
        self.mnem = mnem
        self.ops = ops or []
        self.label = label

    @property
    def is_insn(self):
        return self.kind == "insn"


def _parse(lines):
    entries = []
    for line in lines:
        if line.lstrip().startswith(";"):
            # 整行注释（含后端 IR 提示）：附到上一条，位置不变，且不产生新条目
            # —— 避免打断 R1/R3/R4/R5 的跨指令模式匹配。
            if entries:
                entries[-1].raw += line
            else:
                entries.append(Entry("comment", line))
            continue
        code = line.split(";", 1)[0]
        stripped = code.strip()
        if not stripped:
            entries.append(Entry("blank", line))
            continue
        if stripped.startswith("."):
            entries.append(Entry("directive", line))
            continue
        m = LABEL_RE.match(code)
        if m:
            entries.append(Entry("label", line, label=m.group(1)))
            continue
        m = INSN_RE.match(code)
        if m:
            entries.append(Entry("insn", line, m.group(1).lower(), _split_operands(m.group(2))))
            continue
        entries.append(Entry("blank", line))
    return entries


def _indent(raw: str) -> str:
    return raw[: len(raw) - len(raw.lstrip())]


def _render(indent: str, mnem: str, ops, end="\n") -> str:
    if isinstance(ops, str):
        ops = [] if not ops else [ops]
    if ops:
        return f"{indent}{mnem} {','.join(ops)}{end}"
    return f"{indent}{mnem}{end}"


def _spx_run_amount(e: Entry):
    """返回 (方向, 字节数)，方向为 +1/-1；不是 spx 调整则 None。"""
    if not e.is_insn or e.mnem not in ("inc", "dec") or not e.ops:
        return None
    if _norm_reg(e.ops[0]) != "spx":
        return None
    if len(e.ops) == 1:
        amount = 1
    else:
        m = re.fullmatch(r"#0x([0-9a-fA-F]+)", e.ops[1].strip())
        if not m:
            return None
        amount = int(m.group(1), 16)
    return (1 if e.mnem == "inc" else -1, amount)


class Stream:
    """直块内的值编号状态。令牌相同 => 两个位置当前值相等。"""

    def __init__(self):
        self.vals = {}
        self.seq = 0

    def _fresh(self):
        self.seq += 1
        return ("v", self.seq)

    def token(self, loc: str):
        if loc not in self.vals:
            self.vals[loc] = self._fresh()
        return self.vals[loc]

    def clobber(self, loc: str):
        self.vals[loc] = self._fresh()

    def clear_memstack(self):
        for k in [k for k in self.vals if k.startswith("@spx")]:
            del self.vals[k]

    def reset(self):
        self.vals.clear()


def _apply_generic(stream: Stream, mnem: str, ops):
    """非 mov 指令对状态的影响。返回 True 表示状态被清空。"""
    if mnem in ("push", "pop"):
        stream.clear_memstack()
        if mnem == "pop" and ops:
            loc = _canon_loc(ops[0])
            if loc is not None:
                stream.clobber(loc)
        return False
    if mnem == "nop":
        return False
    # 写 SPX 的指令会移动栈帧，@spx-N 的含义随之改变。
    if ops and _norm_reg(ops[0]) == "spx":
        stream.clear_memstack()
    if mnem in RESET:
        stream.reset()
        return True
    if mnem in WRITE_AB:
        # 结果在 AB：A 与 B 都变。
        stream.clobber("a")
        stream.clobber("b")
        return False
    if mnem in WRITE_DEST:
        if mnem in ("movx", "movc"):
            stream.clobber("a")
            return False
        if ops:
            loc = _canon_loc(ops[0])
            if loc is not None:
                stream.clobber(loc)
        return False
    if mnem == "xch" or mnem == "xchd":
        if ops:
            loc = _canon_loc(ops[0])
            if loc is not None:
                stream.clobber(loc)
        stream.clobber("a")
        return False
    # 未建模：保守清空。
    stream.reset()
    return True


def _mov_state(stream: Stream, dst: str, src: str):
    """`mov dst,src` 的状态更新。返回 True 表示该指令可删除。"""
    dloc = _canon_loc(dst)
    if dloc is None:
        # 间接写（@dr28/@dptr/@ri…）理论上可能别名栈帧，保守清空栈槽跟踪。
        if dst.strip().startswith("@") and _canon_memstack(dst) is None:
            stream.clear_memstack()
        return False  # 目标不跟踪（全局/间接）
    sloc = _canon_loc(src)
    if sloc is not None:
        if stream.token(dloc) == stream.token(sloc):
            return True
        stream.vals[dloc] = stream.token(sloc)
        return False
    if _is_imm(src):
        tok = ("c", src.strip())
        if stream.vals.get(dloc) == tok:
            return True
        stream.vals[dloc] = tok
        return False
    # 间接 / 符号读取：值未知，换新令牌。
    stream.clobber(dloc)
    return False


def _classify_aw(mnem, ops):
    """返回 (读A, 写A)；None 表示无法判断（当作屏障）。"""
    a0 = _norm_reg(ops[0]) if ops else ""
    a1 = _norm_reg(ops[1]) if len(ops) > 1 else ""
    if mnem == "mov":
        return (a1 == "a", a0 == "a")
    if mnem == "push":
        return (a0 == "a", False)
    if mnem == "pop":
        return (False, a0 == "a")
    if mnem == "nop":
        return (False, False)
    if mnem in ("add", "addc", "sub", "subb", "anl", "orl", "xrl",
                "inc", "dec", "clr", "cpl", "rl", "rlc", "rr", "rrc",
                "sra", "srl", "sll", "swap", "da"):
        return (a0 == "a", a0 == "a")
    if mnem in ("mul", "div"):
        return (True, True)
    if mnem in ("movx", "movc"):
        return (True, True)
    if mnem in ("xch", "xchd"):
        return (a0 == "a" or a1 == "a", True)
    # 分支/调用/位操作/未知：当作屏障。
    return None


def _a_dead_after(entries, start):
    """从 start 起在直块内判断 A 是否在被读取前先被覆盖（即当前值无用）。"""
    i = start
    n = len(entries)
    while i < n:
        e = entries[i]
        if not e.is_insn:
            return False
        rw = _classify_aw(e.mnem, e.ops)
        if rw is None:
            return False
        reads_a, writes_a = rw
        if reads_a:
            return False
        if writes_a:
            return True
        i += 1
    return False


def _optimize_once(text: str, rules):
    lines = text.splitlines(keepends=True)
    entries = _parse(lines)
    stats = {"r1": 0, "r2": 0, "r3": 0, "r4": 0, "r5": 0, "r5f": 0,
             "spx_saved": 0, "in_before": 0, "in_after": 0}
    stats["in_before"] = sum(1 for e in entries if e.is_insn)

    out = []
    stream = Stream()
    i = 0
    n = len(entries)
    dead = False  # 刚经过无条件转移，后续指令不可达
    while i < n:
        e = entries[i]

        if not e.is_insn:
            # 标签/指令边界是屏障；整行注释透明（不影响值编号）；空行清状态。
            if e.kind in ("label", "directive"):
                dead = False
                stream.reset()
            elif e.kind == "blank":
                stream.reset()
            out.append(e.raw)
            i += 1
            continue

        # R5b: 无条件转移之后、下一个标签之前的指令不可达 -> 删除。
        if dead:
            stats["r5"] += 1
            i += 1
            continue

        # R5a: 跳到紧随其后的标签（`ejmp L` 紧跟 `L:`）= 空操作 -> 删除跳转。
        if "r5" in rules and e.mnem in UNCOND_JUMP and e.ops:
            target = e.ops[0].strip()
            j = i + 1
            while j < n and entries[j].kind == "blank":
                j += 1
            if j < n and entries[j].kind == "label" and entries[j].label == target:
                stats["r5"] += 1
                i += 1
                continue

        # R1: 合并连续同向 spx 调整。
        if "r1" in rules:
            run = _spx_run_amount(e)
            if run is not None:
                direction, amount = run
                j = i + 1
                count = 1
                while j < n:
                    r2 = _spx_run_amount(entries[j])
                    if r2 is None or r2[0] != direction:
                        break
                    amount += r2[1]
                    count += 1
                    j += 1
                if count > 1 and amount <= 0xFFFF:
                    indent = _indent(e.raw)
                    mnem = "add" if direction > 0 else "sub"
                    out.append(_render(indent, mnem, [f"spx", f"#0x{amount:04x}"], "\n"))
                    stream.clear_memstack()
                    stats["r1"] += 1
                    stats["spx_saved"] += count - 1
                    i = j
                    continue

        # R3/R4: mov a,X ; mov Y,a  ->  mov Y,X 或 mov Y,#C（a 随后无用）。
        if e.mnem == "mov" and len(e.ops) == 2 and _norm_reg(e.ops[0]) == "a":
            nxt = entries[i + 1] if i + 1 < n else None
            if (
                nxt is not None and nxt.is_insn and nxt.mnem == "mov" and len(nxt.ops) == 2
                and _norm_reg(nxt.ops[1]) == "a" and _norm_reg(nxt.ops[0]) != "a"
                and _a_dead_after(entries, i + 2)
            ):
                dst = _norm_reg(nxt.ops[0])
                src = _norm_reg(e.ops[1])
                if "r3" in rules and _can_mov(dst, src):
                    out.append(_render(_indent(e.raw), "mov", [dst, src], "\n"))
                    stream.clobber("a")
                    sloc = _canon_loc(src)
                    if sloc is not None:
                        stream.vals[dst] = stream.token(sloc)
                    else:
                        stream.clobber(dst)
                    stats["r3"] += 1
                    i += 2
                    continue
                if "r4" in rules:
                    # A 的值是编译期常量 -> 直接写进目标寄存器，省去「载入 A 再转存」。
                    tok = None
                    if _is_imm(src):
                        tok = ("c", src.strip())
                    else:
                        sloc = _canon_loc(src)
                        if sloc is not None and isinstance(stream.vals.get(sloc), tuple):
                            cand = stream.vals.get(sloc)
                            if cand and cand[0] == "c":
                                tok = cand
                    if tok is not None and (dst in REG8 or REG8_RE.match(dst)):
                        out.append(_render(_indent(e.raw), "mov", [dst, tok[1]], "\n"))
                        stream.clobber("a")
                        stream.vals[dst] = tok
                        stats["r4"] += 1
                        i += 2
                        continue

        # R2: mov 冗余消除 / 状态推进。
        if e.mnem == "mov" and len(e.ops) == 2:
            if "r2" in rules and _norm_reg(e.ops[0]) == _norm_reg(e.ops[1]):
                stats["r2"] += 1
                i += 1
                continue
            if "r2" in rules and _mov_state(stream, e.ops[0], e.ops[1]):
                stats["r2"] += 1
                i += 1
                continue
            if "r2" not in rules:
                # 仍要推进状态，保持后续判断正确。
                _mov_state(stream, e.ops[0], e.ops[1])
            out.append(e.raw)
            i += 1
            continue

        _apply_generic(stream, e.mnem, e.ops)
        if e.mnem in UNCOND_STOP:
            dead = True
        out.append(e.raw)
        i += 1

    result = "".join(out)
    stats["in_after"] = (stats["in_before"] - stats["r2"] - stats["r3"]
                         - stats["r4"] - stats["r5"] - stats["spx_saved"])
    return result, stats


def optimize(text: str, rules=("r1", "r2", "r3", "r4", "r5")):
    """重复应用规则直到不再变化（R3/R4 可能为后续 R2 创造新机会）。"""
    keys = ("r1", "r2", "r3", "r4", "r5", "spx_saved")
    total = {k: 0 for k in keys}
    cur = text
    in_before = None
    for _ in range(12):
        cur, st = _optimize_once(cur, rules)
        if in_before is None:
            in_before = st["in_before"]
        for k in keys:
            total[k] += st[k]
        if st["in_before"] == st["in_after"]:
            break
    total["in_before"] = in_before
    total["in_after"] = (in_before - total["r2"] - total["r3"] - total["r4"]
                         - total["r5"] - total["spx_saved"])
    return cur, total


def _self_test() -> int:
    """内置回归用例：覆盖 R1~R5。返回 0 通过 / 1 失败。"""
    cases = [
        # (说明, 输入, 期望子串, 期望出现的次数)
        ("R1 合并 spx",
         "\t.area CSEG (CODE)\n_f:\n        inc spx,#0x04\n        inc spx,#0x04\n        inc spx,#0x02\n        ret\n",
         "add spx,#0x000a", 1),
        ("R2 冗余 mov",
         "\t.area CSEG (CODE)\n_f:\n        mov a,@spx-0x04\n        mov r0,a\n        mov a,@spx-0x04\n        ret\n",
         "mov a,@spx-0x04", 1),
        ("R3 mov 合并",
         "\t.area CSEG (CODE)\n_f:\n        mov a,@spx-0x08\n        mov r0,a\n        mov a,@spx-0x07\n        ret\n",
         "mov r0,@spx-0x08", 1),
        ("R4 常量转发",
         "\t.area CSEG (CODE)\n_f:\n        mov a,#0x12\n        mov dpl,a\n        mov a,#0x34\n        ret\n",
         "mov dpl,#0x12", 1),
        ("屏障不跨标签",
         "\t.area CSEG (CODE)\n_f:\n        mov a,@spx-0x04\nL_x:\n        mov r0,a\n        ret\n",
         "mov r0,@spx-0x04", 0),
        ("R5a 删除自跳转",
         "\t.area CSEG (CODE)\n_f:\n        ejmp L1\nL1:\n        ret\n",
         "ejmp", 0),
        ("R5b 删除转移后的死代码",
         "\t.area CSEG (CODE)\n_f:\n        eret\n        mov a,#0x01\nL2:\n        ret\n",
         "mov a,#0x01", 0),
        ("R5 遇标签即恢复可达",
         "\t.area CSEG (CODE)\n_f:\n        ejmp L1\nL_mid:\n        mov a,#0x01\nL1:\n        ret\n",
         "mov a,#0x01", 1),
    ]
    failed = 0
    for name, src, needle, expect in cases:
        out, _ = optimize(src)
        got = out.count(needle)
        ok = got == expect
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}: '{needle}' 出现 {got} 次（期望 {expect}）")
        if not ok:
            failed += 1
            print("---- 输出 ----")
            print(out)
    if failed:
        print(f"自我测试失败：{failed}/{len(cases)}")
        return 1
    print(f"自我测试通过：{len(cases)}/{len(cases)}")
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="MCS 后端汇编局部优化（无需重编 zig）。")
    ap.add_argument("asm", nargs="?", help="输入的 .asm 文件")
    ap.add_argument("-o", "--out", help="输出文件（默认就地改写）")
    ap.add_argument("--self-test", action="store_true", help="运行内置回归用例后退出")
    ap.add_argument("--stats", action="store_true", help="打印优化统计")
    ap.add_argument("--no-r1", action="store_true", help="关闭 spx 调整合并")
    ap.add_argument("--no-r2", action="store_true", help="关闭冗余 mov 删除")
    ap.add_argument("--no-r3", action="store_true", help="关闭 mov 合并")
    ap.add_argument("--no-r4", action="store_true", help="关闭常量转发")
    ap.add_argument("--no-r5", action="store_true", help="关闭无用代码/跳转回收")
    args = ap.parse_args(argv)

    if args.self_test:
        return _self_test()

    if not args.asm:
        ap.error("需要指定 .asm 文件（或用 --self-test）")

    path = Path(args.asm)
    if not path.is_file():
        print(f"错误：找不到文件 {path}", file=sys.stderr)
        return 2
    text = path.read_text(encoding="utf-8", errors="surrogateescape")

    rules = []
    if not args.no_r1:
        rules.append("r1")
    if not args.no_r2:
        rules.append("r2")
    if not args.no_r3:
        rules.append("r3")
    if not args.no_r4:
        rules.append("r4")
    if not args.no_r5:
        rules.append("r5")

    new_text, stats = optimize(text, tuple(rules))
    out_path = Path(args.out) if args.out else path
    out_path.write_text(new_text, encoding="utf-8", errors="surrogateescape")

    if args.stats:
        print(
            f"mcs_opt: {path.name}: 指令 {stats['in_before']} -> {stats['in_after']} "
            f"(省 {stats['in_before'] - stats['in_after']})；"
            f"R1 spx 合并 {stats['r1']} 组(省 {stats['spx_saved']})，"
            f"R2 冗余 mov {stats['r2']}，R3 mov 合并 {stats['r3']}，"
            f"R4 常量转发 {stats['r4']}，R5 无用代码 {stats['r5']}"
        )
    else:
        print(f"已优化 {path.name}: 指令 {stats['in_before']} -> {stats['in_after']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
