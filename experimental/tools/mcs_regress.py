#!/usr/bin/env python3
"""mcs_regress.py —— 优化回归：断言式（指令预算）+ E2 差分（base vs opt）。

背景（见 `docs/17`）：构建层后处理链路 `fix_mcs_labels -> mcs_opt -> mcs_ir`，
其中 `mcs_ir.py` 做**值级**死 store/死寄存器/死帧槽消除。历史上有过「按 asm 文本假设
帧布局」的严重 bug（帧槽相对 SPX，`push/pop` 会移动 SPX，`ziglog` 真机 0 字节）。
本工具给这条文本级优化兜底：

  差分（E2）：`MCS_KEEP_BASE=1` 构建会额外产出 `<x>.asm.base`（= fix+mcs_opt，`mcs_ir`
  之前）。本工具逐行比对 base 与最终 opt，**断言**：
    - opt 只能是 base **删掉若干行**（不许新增/改写/重排）；
    - 被删的行只允许：IR 提示 `; vN …`、冷热标签 `; @tag …`、以及
      `mov @spx<d>,X`（帧槽写）/`mov rN,X`（rN=r0..r7）；
    - 删掉的帧槽 store 所在函数**不能含 `push/pop`**（SPX 位移会让文本偏移失真；
      这正是 ziglog 真机 0 字节的根因，`mcs_ir` 已整体跳过这类函数）。

  断言（预算）：`--budget <stem>=<n>` 或内置预算表，断言最终 opt 指令数 <= n
  （"CSEG 必须降到阈值"），并打印 base->opt 的降幅。

用法：
  python tools/mcs_regress.py --self-test
  python tools/mcs_regress.py <base.asm> <opt.asm> [<base2> <opt2> ...] [--require-reduction]
  python tools/mcs_regress.py --auto <opt.asm> ...      # base 取 <opt>.asm.base
  python tools/mcs_regress.py --auto <opt.asm> --budget mem=420
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mcs_ir  # noqa: E402  （复用同目录工具，保证与构建链路同一套规则）

# 内置预算表（最终 opt 的指令数上限）。键为 **asm 文件名 stem**（不含扩展名），
# 值为实测基线 + 约 10% 余量；`-Dmcs-small=true` 只会更小，不影响上限断言。
BUDGETS = {
    "opt": 285,       # zigopt
    "ns": 210,        # zigns
    "mem": 420,       # zigmem
    "slice": 1140,    # zigslice
    "log": 3600,      # ziglog
    "buzzer": 3700,   # zigbuzz
    "rtindex": 600,   # zigrtindex
    "hotcold": 215,   # zighotcold
}


class RegressError(Exception):
    pass


def count_insn(lines):
    """统计指令行（排除空行/注释/`.directive`/标签）。"""
    n = 0
    for ln in lines:
        body = ln.split(";", 1)[0]
        if not body.strip():
            continue
        if body.lstrip().startswith("."):
            continue
        if mcs_ir.LABEL_RE.match(body):
            continue
        if mcs_ir.INSN_RE.match(body):
            n += 1
    return n


def _diff_deletions(base, opt):
    """按顺序把 opt 对齐到 base，返回被删行 [(base_idx, line)]。

    opt 必须是 base 的**子序列**；否则抛错（新增/改写/重排都是回归）。
    """
    deleted = []
    i = 0
    for ob in opt:
        while i < len(base) and base[i] != ob:
            deleted.append((i, base[i]))
            i += 1
        if i >= len(base):
            raise RegressError("opt 含 base 中不存在的行（被改写/新增/重排）：%r" % ob)
        i += 1
    while i < len(base):
        deleted.append((i, base[i]))
        i += 1
    return deleted


def _func_of(base, starts, idx):
    """idx 所在函数名（最近的 `_func:` 标号）。"""
    name, lineno = "?", -1
    for s in starts:
        if s <= idx:
            name, lineno = base[s].strip().rstrip(":"), s
        else:
            break
    return name, lineno


def _classify_deletion(line):
    """返回 ('comment'|'spx'|'reg'|None, 说明)。只做结构判定，不做 SPX 安全性判定。"""
    stripped = line.rstrip("\n")
    if stripped.lstrip().startswith(";"):
        if mcs_ir.TRACE_RE.match(stripped) or mcs_ir.TAG_RE.match(stripped):
            return "comment", ""
        return None, "删除了非 IR/标签注释：%s" % stripped.strip()

    info = mcs_ir._line_info(line)
    if info is None:
        return None, "删除了空行"
    if info[0] != "insn":
        return None, "删除了非指令行：%s" % stripped.strip()

    mnem, ops = info[1], info[2]
    if mnem != "mov" or len(ops) != 2:
        return None, "删除了非 `mov`：%s" % stripped.strip()

    dest = ops[0].strip().lower()
    if mcs_ir.slot_of(dest):
        return "spx", mcs_ir.slot_of(dest)
    # 块内 DSE 也会删寄存器写（a/b/dpl/dph/r0-r7）；此处只做结构断言（非帧槽即寄存器）。
    regs = mcs_ir.regs_of(dest)
    if len(regs) == 1:
        return "reg", next(iter(regs))
    return None, "删除了非帧槽/非寄存器的 mov：%s" % stripped.strip()


def trace_deletions(base):
    """复刻 `optimize` 的迭代，返回 {base 行号: 'block'|'slot'|'reg'}。

    用于**判定删除来源**：`slot`=全函数死槽（帧槽相对 SPX，含 push/pop 时不安全）；
    `block`=块内 DSE（push/pop 是屏障，安全）；`reg`=全函数死寄存器写。
    """
    cur = list(base)
    origin = list(range(len(base)))
    rule_of = {}
    for _ in range(12):
        d = {}
        for k in mcs_ir._whole_slot_dead(cur):
            d[k] = "slot"
        for k in mcs_ir._whole_reg_dead(cur):
            d.setdefault(k, "reg")
        for k in mcs_ir._block_dse(cur):
            d.setdefault(k, "block")
        if not d:
            break
        nc, no = [], []
        for k, l in enumerate(cur):
            if k in d:
                rule_of[origin[k]] = d[k]
            else:
                nc.append(l)
                no.append(origin[k])
        cur, origin = nc, no
    return rule_of


def _func_span_of(base, starts, idx):
    return mcs_ir._func_span(starts, idx, len(base))


def analyze(base, opt, name="asm"):
    """差分 + 安全断言；返回统计 dict，违规则抛 RegressError。"""
    deleted = _diff_deletions(base, opt)
    starts = mcs_ir._func_starts(base)
    rule_of = trace_deletions(base)
    by_func = {}
    counts = {"comment": 0, "spx": 0, "reg": 0}
    for idx, line in deleted:
        kind, detail = _classify_deletion(line)
        if kind is None:
            raise RegressError("%s: %s" % (name, detail))
        if kind in ("spx", "reg"):
            rule = rule_of.get(idx)
            if rule is None:
                raise RegressError("%s: 指令删除无法归因（%s）：%s"
                                   % (name, kind, line.strip()))
            if kind == "spx" and rule == "slot":
                start, end = _func_span_of(base, starts, idx)
                if mcs_ir._spx_moves(base, start, end):
                    raise RegressError(
                        "%s: 含 push/pop 的函数里用「全函数死槽」删了帧槽 store"
                        "（SPX 文本偏移会失真）：%s" % (name, line.strip()))
        counts[kind] += 1
        fname, _ = _func_of(base, starts, idx)
        d = by_func.setdefault(fname, {"comment": 0, "spx": 0, "reg": 0})
        d[kind] += 1
    return {
        "name": name,
        "base": count_insn(base),
        "opt": count_insn(opt),
        "deleted_lines": len(deleted),
        "counts": counts,
        "by_func": by_func,
        "rules": {r: sum(1 for v in rule_of.values() if v == r)
                  for r in ("block", "slot", "reg")},
    }


def check_pair(base_path, opt_path):
    base = Path(base_path).read_text(encoding="utf-8").splitlines(keepends=True)
    opt = Path(opt_path).read_text(encoding="utf-8").splitlines(keepends=True)
    # 先验证 opt == optimize(base)（与构建链路同一套规则，防止产物/工具不同步）。
    expect = mcs_ir.optimize(base)
    if "".join(expect) != "".join(opt):
        ei = next((k for k in range(max(len(expect), len(opt)))
                   if (expect[k] if k < len(expect) else None)
                   != (opt[k] if k < len(opt) else None)), 0)
        raise RegressError("%s: 最终 asm 与当前 mcs_ir 结果不一致（第 %d 行）——"
                           "产物过期或工具改动未回灌" % (Path(opt_path).name, ei + 1))
    return analyze(base, opt, name=Path(opt_path).stem)


def report(stats, budget=None, require_reduction=False):
    c = stats["counts"]
    dropped = stats["base"] - stats["opt"]
    pct = (100.0 * dropped / stats["base"]) if stats["base"] else 0.0
    print("[regress] %s: 指令 %d -> %d（-%.1f%%；删行 %d：注释 %d/帧槽 %d/寄存器 %d）"
          % (stats["name"], stats["base"], stats["opt"], pct, stats["deleted_lines"],
             c["comment"], c["spx"], c["reg"]))
    for fname, d in sorted(stats["by_func"].items()):
        if d["spx"] or d["reg"]:
            print("            %s: 帧槽 %d / 寄存器 %d" % (fname, d["spx"], d["reg"]))
    if require_reduction and dropped <= 0:
        raise RegressError("%s: 未产生任何指令削减（优化失效？）" % stats["name"])
    if budget is not None and stats["opt"] > budget:
        raise RegressError("%s: 指令数 %d 超预算 %d" % (stats["name"], stats["opt"], budget))


# --- 自测 -------------------------------------------------------------------
def _self_test():
    # 1) 正常删除：帧槽/寄存器/注释 -> 通过。
    base = (
        "_f:\n"
        "; v0 arg -> @spx-1\n"
        "        mov a,#0x01\n"
        "        mov @spx-1,a\n"
        "        mov r6,a\n"
        "        mov a,#0x02\n"
        "        mov @spx-1,a\n"
        "        mov a,@spx-1\n"
        "        mov dpl,a\n"
        "; @tag func _f Ofast\n"
    )
    opt = "".join(mcs_ir.optimize(base.splitlines(keepends=True)))
    stats = analyze(base.splitlines(keepends=True), opt.splitlines(keepends=True))
    assert stats["counts"]["spx"] == 1 and stats["counts"]["reg"] >= 1, stats

    # 2) 检出「在含 push 的函数里删帧槽 store」。
    base = (
        "_f:\n"
        "        push acc\n"
        "        mov a,#0x12\n"
        "        mov @spx-0x10,a\n"
        "        pop acc\n"
        "        eret\n"
    )
    bad = base.replace("        mov @spx-0x10,a\n", "")
    try:
        analyze(base.splitlines(keepends=True), bad.splitlines(keepends=True))
        raise AssertionError("应检出 push 函数中的危险删除")
    except RegressError:
        pass

    # 3) 检出「新增/改写」。
    try:
        analyze(("_f:\n        eret\n").splitlines(keepends=True),
                ("_f:\n        ret\n").splitlines(keepends=True))
        raise AssertionError("应检出改写")
    except RegressError:
        pass

    # 4) 检出「删注释以外的非指令行」。
    try:
        analyze(("_f:\n        .area CSEG\n        eret\n").splitlines(keepends=True),
                ("_f:\n        eret\n").splitlines(keepends=True))
        raise AssertionError("应检出非法删除")
    except RegressError:
        pass

    # 5) 模拟历史 bug（全函数死槽规则不再跳过 push/pop 函数）-> 必须被检出。
    orig = mcs_ir._whole_slot_dead

    def _buggy_whole_slot_dead(lines):  # 旧版：不排除含 push/pop 的函数
        starts = mcs_ir._func_starts(lines)
        delete = set()
        for i, ln in enumerate(lines):
            sm = mcs_ir.STORE_RE.match(ln)
            if not sm:
                continue
            slot = mcs_ir.norm_slot(sm.group("off"))
            start, end = mcs_ir._func_span(starts, i, len(lines))
            read = False
            for j in range(start, end):
                if j == i or lines[j].lstrip().startswith(";"):
                    continue
                if not any(mcs_ir.norm_slot(m.group("off")) == slot
                           for m in mcs_ir.MEM_RE.finditer(lines[j])):
                    continue
                smj = mcs_ir.STORE_RE.match(lines[j])
                if smj is None or mcs_ir.norm_slot(smj.group("off")) != slot:
                    read = True
                    break
            if not read:
                delete.add(i)
        return delete

    mcs_ir._whole_slot_dead = _buggy_whole_slot_dead
    try:
        base = ("_f:\n        push acc\n        mov a,#0x12\n"
                "        mov @spx-0x10,a\n        pop acc\n        eret\n")
        opt = "".join(mcs_ir.optimize(base.splitlines(keepends=True)))
        try:
            analyze(base.splitlines(keepends=True), opt.splitlines(keepends=True))
            raise AssertionError("应检出 push 函数中「全函数死槽」的危险删除")
        except RegressError:
            pass
    finally:
        mcs_ir._whole_slot_dead = orig

    print("mcs_regress: self-test OK")


def main(argv):
    if len(argv) > 1 and argv[1] == "--self-test":
        _self_test()
        return 0

    require_reduction = "--require-reduction" in argv
    budgets = dict(BUDGETS)
    files, i = [], 1
    while i < len(argv):
        a = argv[i]
        if a == "--budget" and i + 1 < len(argv):
            stem, n = argv[i + 1].split("=", 1)
            budgets[stem] = int(n)
            i += 2
            continue
        if not a.startswith("--"):
            files.append(a)
        i += 1

    # 位置参数按 (base, opt) 成对给出，可多对；`--auto` 时每个参数是 opt，base 取 `<opt>.base`。
    if "--auto" in argv:
        pairs = [(f + ".base", f) for f in files]
    else:
        if len(files) < 2 or len(files) % 2 != 0:
            print(__doc__)
            return 2
        pairs = [(files[k], files[k + 1]) for k in range(0, len(files), 2)]

    failed = 0
    for base_path, opt_path in pairs:
        stem = Path(opt_path).stem
        try:
            stats = check_pair(base_path, opt_path)
            report(stats, budget=budgets.get(stem), require_reduction=require_reduction)
        except RegressError as e:
            print("[regress] FAIL: %s" % e)
            failed += 1
        except FileNotFoundError as e:
            print("[regress] FAIL: 找不到 %s（构建时需 MCS_KEEP_BASE=1）" % e.filename)
            failed += 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
