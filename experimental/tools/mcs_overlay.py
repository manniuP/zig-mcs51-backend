#!/usr/bin/env python3
"""MCS-51 静态帧叠加工具 —— 把 Zig 后端每函数一块的 `_frkN` idata 帧叠加复用。

背景（见 `docs/交接-2026-09-15.md` §10、§12）：
    MCS-51 后端把每个函数的局部量放一块**静态 idata 帧**（`.area DSEG` + `_frkN:` + `.ds n`），
    函数多了 idata(256B) 就爆（8 位 Zig COBS 有 11 个帧 ≈ 400B，`ASlink` 报
    `Could not get ... consecutive bytes ... DSEG`）。
    而 8051 非重入代码里，**不在同一调用链上的函数，其帧可以复用同一段 RAM**。

原理：把每个 `_frkN` 叠加到**一个共享区** `_frk_ovl` 的不同偏移：
    若 A 能（经调用图）到达 B 或反之，则 A、B 的帧必须**不相交**（可能同时在栈上）；
    否则可重叠。用「不相容图 + 贪心放置」求偏移。取址函数（疑似函数指针）保守地
    与所有函数不相容。递归不额外处理——后端静态帧本就不支持重入。

用法：
    python mcs_overlay.py <file.asm>            # 就地改写
    python mcs_overlay.py <in.asm> -o <out.asm>
    python mcs_overlay.py <file.asm> --stats    # 打印叠加前后字节数
    python mcs_overlay.py --self-test           # 内置回归

只处理 `_frk<digits>` 形式、且紧邻 `.ds n` 的帧符号；其它 DSEG 符号（如 `.data` 全局）
原样保留。**S1 阶段尚未接入构建**（`xmake` 未调用本工具）。
"""

import argparse
import re
import sys
from pathlib import Path

FRAME_RE = re.compile(r"(?<![A-Za-z0-9_])_frk\d+")
GLOBAL_LABEL = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):")
# 调用指令（mcs51）：lcall/acall 目标符号。
CALL_RE = re.compile(r"\b(?:lcall|acall)\s+([A-Za-z_][A-Za-z0-9_]*)")
# 任一符号 token（含 `_frkN+5` 这种带偏移），用于「取址 / 引用」判定。
SYM_RE = re.compile(r"[_A-Za-z][A-Za-z0-9_]*")


def _parse_lines(text):
    return text.splitlines(keepends=True)


def _classify(line):
    """返回 ('directive'|'label'|'insn'|'blank', payload)。"""
    code, _, _ = line.partition(";")
    s = code.strip()
    if not s:
        return ("blank", None)
    if s.startswith("."):
        return ("directive", s)
    m = GLOBAL_LABEL.match(code)
    if m:
        return ("label", m.group(1))
    return ("insn", code)


def analyze(text):
    """收集 _frk 帧（符号→字节数）与函数调用图。"""
    lines = _parse_lines(text)
    # 帧大小：`_frkN:` 下一行（跳过空/注释）的 `.ds n`
    frames = {}
    for i, ln in enumerate(lines):
        m = re.match(r"^(_frk\d+):", ln)
        if not m:
            continue
        sym = m.group(1)
        for j in range(i + 1, min(i + 4, len(lines))):
            dm = re.match(r"^\s*\.ds\s+(\d+)", lines[j])
            if dm:
                frames[sym] = int(dm.group(1))
                break
    # 全局符号（.globl 声明）；函数 = CODE 区里被 .globl 声明的标签（排除 _frk）。
    globl = set()
    for ln in lines:
        gm = re.match(r"^\s*\.globl\s+([A-Za-z_][A-Za-z0-9_]*)", ln)
        if gm:
            globl.add(gm.group(1))
    funcs = []  # (name, start_line, end_line)
    cur = None
    start = 0
    area = ""
    for i, ln in enumerate(lines):
        k, p = _classify(ln)
        if k == "directive":
            if p.startswith(".area"):
                area = p
            continue
        if k == "label" and not p.startswith("_frk") and ("CODE" in area or "CSEG" in area):
            # 函数 = CODE 标签且非局部标签（`L_...` / `L<数字>`）
            is_local = re.match(r"^L(\d+|_.*)", p) is not None and p not in globl
            if p in globl or not is_local:
                if cur:
                    funcs.append((cur, start, i))
                cur, start = p, i
    if cur:
        funcs.append((cur, start, len(lines)))

    # 每个函数：自己的帧（首个引用）、被调用符号、取址符号。
    fn_frame = {}
    edges = {name: set() for name, _, _ in funcs}
    escaped = set()
    known = {name for name, _, _ in funcs}
    for name, a, b in funcs:
        body = "".join(lines[a:b])
        fs = FRAME_RE.search(body)
        if fs:
            sym = fs.group(0)
            if sym in frames:
                fn_frame[name] = sym
        # 调用边
        for tgt in CALL_RE.findall(body):
            if tgt in known and tgt != name:
                edges[name].add(tgt)
        # 取址：符号被引用但不是本行调用目标 → 保守视为取址
        for ln in body.splitlines():
            if not ln.strip() or ln.strip().startswith("."):
                continue
            call_targets = set(CALL_RE.findall(ln))
            for tok in SYM_RE.findall(ln):
                if tok in known and tok != name and tok not in call_targets:
                    escaped.add(tok)
    return lines, frames, funcs, fn_frame, edges, escaped


def reachable(edges, known):
    """返回 reach[u] = 从 u 可达的函数集合（含 u 自身）。"""
    reach = {}
    for u in known:
        seen = {u}
        stack = [u]
        while stack:
            x = stack.pop()
            for y in edges.get(x, ()):
                if y not in seen:
                    seen.add(y)
                    stack.append(y)
        reach[u] = seen
    return reach


def assign_offsets(fn_frame, frames, edges, escaped):
    """贪心把各函数帧放进共享区，返回 (sym→base, total)。"""
    funcs = list(fn_frame.keys())
    known = set(funcs)
    reach = reachable(edges, known)

    def incompatible(a, b):
        if a == b:
            return True
        if a in escaped or b in escaped:
            return True  # 取址函数保守：与所有帧不相容
        return b in reach[a] or a in reach[b]

    # 大帧优先放置
    order = sorted(funcs, key=lambda f: -frames[fn_frame[f]])
    bases = {}
    placed = []
    total = 0
    for f in order:
        size = frames[fn_frame[f]]
        # 找不与已放好的「不相容」帧重叠的最小偏移
        off = 0
        while True:
            conflict = False
            for (g, gb) in placed:
                if incompatible(f, g) and off < gb + frames[fn_frame[g]] and gb < off + size:
                    conflict = True
                    off = gb + frames[fn_frame[g]]
                    break
            if not conflict:
                break
        bases[f] = off
        placed.append((f, off))
        total = max(total, off + size)
    return bases, total


def rewrite(text, bases, frames, fn_frame):
    """把 `_frkN` 引用改写到 `_frk_ovl+base`，并把各帧定义合成一个共享区。"""
    sym_base = {fn_frame[f]: bases[f] for f in fn_frame}
    total = max((bases[f] + frames[fn_frame[f]] for f in fn_frame), default=0)

    out = []
    emitted_ovl = False
    i = 0
    lines = _parse_lines(text)
    while i < len(lines):
        ln = lines[i]
        m = re.match(r"^(_frk\d+):\s*$", ln)
        if m and m.group(1) in sym_base:
            # 跳过该帧的 `_frkN:` + 紧随的 `.ds n`（可能夹空行）
            emitted = False
            j = i + 1
            if not emitted_ovl:
                out.append("_frk_ovl:\n")
                out.append("\t.ds %d\n" % total)
                emitted_ovl = True
                emitted = True
            # 跳到 `.ds` 之后
            while j < len(lines) and not re.match(r"^\s*\.ds\s+\d+", lines[j]):
                if lines[j].strip() == "":
                    j += 1
                    continue
                break
            if j < len(lines) and re.match(r"^\s*\.ds\s+\d+", lines[j]):
                j += 1
            i = j
            continue
        # 普通行：重写 `_frkN` 引用（含 +k/-k 偏移）为 `_frk_ovl+(base+k)`
        def _fix(mm):
            sym = "_frk" + mm.group(1)
            base = sym_base.get(sym)
            if base is None:
                return mm.group(0)
            off = int(mm.group(2)) if mm.group(2) else 0
            total_off = base + off
            return "_frk_ovl" + (("+%d" % total_off) if total_off else "")
        out.append(re.sub(r"(?<![A-Za-z0-9_])_frk(\d+)((?:\+|-)\d+)?", _fix, ln))
        i += 1
    return "".join(out)


def optimize(text):
    lines, frames, funcs, fn_frame, edges, escaped = analyze(text)
    if not fn_frame:
        return text, {"frames": 0, "before": 0, "after": 0}
    bases, total = assign_offsets(fn_frame, frames, edges, escaped)
    before = sum(frames[fn_frame[f]] for f in fn_frame)
    new_text = rewrite(text, bases, frames, fn_frame)
    return new_text, {"frames": len(fn_frame), "before": before, "after": total}


def _self_test():
    # 三个函数：a 调 b；c 独立。a=10,b=20,c=30 字节。
    # a 与 b 不相容（调用链）；c 可与 a 或 b 重叠。
    # 贪心应按大小降序：c(30)@0, b(20)@0, a(10) 与 b 不相容 -> @20。总 30。
    src = (
        "\t.area DSEG\n_frk1:\n\t.ds 10\n"
        "\t.area DSEG\n_frk2:\n\t.ds 20\n"
        "\t.area DSEG\n_frk3:\n\t.ds 30\n"
        "\t.area CSEG (CODE)\n"
        "_a:\n\tmov _frk1,a\n\tlcall _b\n\tret\n"
        "_b:\n\tmov _frk2+1,a\n\tret\n"
        "_c:\n\tmov _frk3,a\n\tret\n"
    )
    out, st = optimize(src)
    ok = True
    if st["before"] != 60:
        print("FAIL: before=%d != 60" % st["before"])
        ok = False
    if st["after"] != 30:
        print("FAIL: after=%d != 30 (期望 30)" % st["after"])
        ok = False
    if out.count("_frk_ovl:") != 1:
        print("FAIL: 应只有一个 _frk_ovl")
        ok = False
    if "_frk1" in out or "_frk2" in out or "_frk3" in out:
        print("FAIL: 旧帧符号未清理")
        ok = False
    print("自我测试 %s：frames=%d before=%d after=%d" %
          ("通过" if ok else "失败", st["frames"], st["before"], st["after"]))
    return 0 if ok else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description="MCS-51 静态帧叠加（asm 级，无需重编编译器）")
    ap.add_argument("asm", nargs="?")
    ap.add_argument("-o", "--out")
    ap.add_argument("--stats", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv)

    if args.self_test:
        return _self_test()
    if not args.asm:
        ap.error("需要 .asm 文件（或用 --self-test）")

    p = Path(args.asm)
    if not p.is_file():
        print("错误：找不到文件 %s" % p, file=sys.stderr)
        return 2
    text = p.read_text(encoding="utf-8", errors="surrogateescape")
    new_text, st = optimize(text)
    out_path = Path(args.out) if args.out else p
    out_path.write_text(new_text, encoding="utf-8", errors="surrogateescape")
    if args.stats:
        print("mcs_overlay: %s: 帧 %d, DSEG %d -> %d 字节（省 %d）" %
              (p.name, st["frames"], st["before"], st["after"], st["before"] - st["after"]))
    else:
        print("已叠加 %s: DSEG %d -> %d" % (p.name, st["before"], st["after"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
