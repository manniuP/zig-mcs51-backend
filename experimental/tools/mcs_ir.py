#!/usr/bin/env python3
"""mcs_ir.py —— 消费后端 IR 提示（`; vN ...`）做值级优化，并删掉提示。

后端在每条 AIR 指令前输出：`; v<inst> <tag> <操作数…> [-> @spx<disp>]`。
本工具夹在 `mcs_opt.py` 之后、`sdas` 之前，做**可证明安全**的局部改写并删除提示注释：

  1) **全函数死 store（帧槽从不被读）**：`mov @spx<d>,X` 若 `@spx<d>` 在该函数内**从不被读**
     （只被写）→ 删掉（同一槽被写多次但从不读时，这些 store 全删）。扫描必须覆盖**整个函数**
     （含循环回边：循环尾 store、循环头 read 在更小地址处），只看 store 之后会误删循环变量。
     **含 `push/pop`/`spx` 调整的函数整体跳过**：帧槽相对 SPX，push/pop 会移动 SPX，使同一逻辑槽
     的**文本偏移改变**（如 `-0x10` 在 `push acc` 后读作 `-0x11`），按文本偏移判读会误删
     （`ziglog` 的压栈传参即中招）。见 `_spx_moves`。

  2) **基本块内死写（DSE）**：在直线块内，`mov L,X`（L 为 `@spx<d>` 或寄存器）若其**下一次
     访问 L** 也是写（值在被读前就被覆盖），则这条写是死写 → 删掉。块以标签/分支/调用/返回
     /`.area` 为界；遇到 `push/pop`、`spx` 调整、间接内存（`@rN/@dptr/@dpx/@dr28`）、未建模
     指令等屏障即停止（保守：不跨越屏障删）。写入多字节只按各自槽判定。

  3) **全函数死寄存器写**：`mov rN,X`（X 为寄存器/立即数/帧槽，无副作用）若 rN 在整个函数内
     从不被读（显式读、`push rN`、`@rN` 间接等），则该写是死写 → 删掉。含未建模指令时放弃
     （未建模可能隐式读寄存器）。只处理 `mov`（不碰标志位）。

  4) 删掉所有 IR 提示注释。所有规则反复迭代至不再变化。

用法：python tools/mcs_ir.py <a.asm> [b.asm ...]
      python tools/mcs_ir.py --self-test
      python tools/mcs_ir.py <a.asm> --stats
"""
import re
import sys
from pathlib import Path

# --- 行分类 -----------------------------------------------------------------
TRACE_RE = re.compile(r"^\s*;\s*v\d+\s+\S+")
# 冷热标签注释（后端 `link/Asx.zig` 发出）：`; @tag <func|sym> <name> <hot|cold|default>`。
TAG_RE = re.compile(r"^\s*;\s*@tag\s+(\S+)\s+(\S+)\s+(\S+)")
# 最近一次 optimize() 解析到的标签：[(kind, name, tag), ...]
TAGS = []
LABEL_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*):")
GFUNC_RE = re.compile(r"^_\w+:\s*$")
MEM_RE = re.compile(r"@spx(?P<off>-?0x[0-9a-fA-F]+|-?\d+)?")
STORE_RE = re.compile(r"^\s*mov\s+@spx(?P<off>-?0x[0-9a-fA-F]+|-?\d+)?\s*,")
INSN_RE = re.compile(r"^\s+([A-Za-z][A-Za-z0-9_]*)\b\s*(.*)$")

SPX_FULL = re.compile(r"^@spx(?:([+-])0x([0-9a-f]+)|([+-])(\d+))?$")
SINGLE_RE = re.compile(r"^(a|b|dpl|dph|dpxl|r[0-7])$")
# 控制流：结束基本块（条件/无条件跳转、调用、返回）。
FLOW = {
    "ajmp", "ejmp", "ljmp", "sjmp", "jmp", "jc", "jnc", "jz", "jnz", "je", "jne",
    "jg", "jle", "jsl", "jsle", "jsg", "jsge", "jbc", "jb", "jnb", "cjne", "djnz",
    "acall", "ecall", "lcall", "ret", "reti", "eret", "trap", "esc",
}
CALL = {"acall", "ecall", "lcall"}
# 读-改-写单目（读写第一操作数）。
RMW = {"cpl", "rl", "rlc", "rr", "rrc", "sra", "srl", "sll", "swap", "da"}
WRITEONLY = {"clr"}
ARITH2 = {"add", "addc", "sub", "subb", "anl", "orl", "xrl"}


def norm_slot(off):
    return "@spx%+d" % (0 if off is None else int(off, 0))


def slot_of(op):
    """`@spx<d>` -> 'spx<+d>'；否则 None。"""
    m = SPX_FULL.match(op.strip().lower())
    if not m:
        return None
    off = 0
    if m.group(2):
        off = int(m.group(2), 16)
    elif m.group(4):
        off = int(m.group(4))
    if m.group(1) == "-" or m.group(3) == "-":
        off = -off
    return "spx%+d" % off


def is_imm(op):
    return op.strip().startswith("#")


def is_indirect(op):
    """间接内存（@rN/@dptr/@dpx/@dr28/@a+dptr…）——可能别名栈帧，作屏障。"""
    o = op.strip().lower()
    return o.startswith("@") and SPX_FULL.match(o) is None


def regs_of(op):
    """把操作数展开成受跟踪的寄存器集合（dptr→dpl,dph；dr28 不可跟踪）。"""
    o = op.strip().lower()
    if SINGLE_RE.match(o):
        return {o}
    if o == "dptr":
        return {"dpl", "dph"}
    if o in ("dr28", "dpx"):
        return set()
    return set()


def indirect_regs(op):
    """间接操作数（@rN/@dptr/@dpx…）隐含读取的寄存器。"""
    o = op.strip().lower()
    if not o.startswith("@"):
        return set()
    m = re.findall(r"@r([0-7])", o)
    if m:
        return {"r" + x for x in m}
    if "@dptr" in o:
        return {"dpl", "dph"}
    if "@dpx" in o:
        return {"dpxl"}
    return set()


def classify(mnem, ops, raw):
    """返回 (reads, writes, barrier, unknown)。

    reads/writes：受跟踪位置（寄存器单字节 / `spx<+d>` 帧槽）。
    barrier：指令可能读写未知内存或移动栈（不可跨越做局部优化）。
    unknown：未建模指令（可能隐式读写任意寄存器，用于保守放弃全函数分析）。
    """
    reads, writes = set(), set()
    barrier = False
    unknown = False
    low = raw.strip().lower()

    # spx 调整（帧基址移动）：所有 @spx 偏移含义改变。
    if re.match(r"^(add|sub|inc|dec)\s+spx\b", low):
        return reads, writes, True, False

    # 间接寻址隐含读取地址寄存器（@rN→rN，@dptr→dpl/dph…）。
    for op in ops:
        if is_indirect(op):
            reads |= indirect_regs(op)

    if mnem == "mov":
        if len(ops) != 2:
            return reads, writes, True, False
        d, s = ops[0].strip().lower(), ops[1].strip().lower()
        if is_indirect(d) or is_indirect(s):
            barrier = True
        if not is_indirect(d):
            sl = slot_of(d)
            if sl:
                writes.add(sl)
            else:
                writes |= regs_of(d)
        if not is_indirect(s):
            sl = slot_of(s)
            if sl:
                reads.add(sl)
            else:
                reads |= regs_of(s)
        return reads, writes, barrier, unknown

    if mnem in ARITH2:
        d = ops[0].strip().lower() if ops else ""
        if d == "c":  # 对进位操作：不跟踪（a 也可能被读，保守加 a）
            if len(ops) > 1:
                reads |= regs_of(ops[1])
            return reads, writes, barrier, unknown
        sl = slot_of(d)
        if sl:
            reads.add(sl)
            writes.add(sl)
        elif is_indirect(d):
            barrier = True
        else:
            rs = regs_of(d)
            reads |= rs
            writes |= rs
        if len(ops) > 1:
            if is_indirect(ops[1]):
                barrier = True
            sl = slot_of(ops[1])
            if sl:
                reads.add(sl)
            else:
                reads |= regs_of(ops[1])
        return reads, writes, barrier, unknown

    if mnem in ("inc", "dec"):
        if not ops:
            return reads, writes, True, False
        d = ops[0].strip().lower()
        if d == "spx":
            return reads, writes, True, False
        sl = slot_of(d)
        if sl:
            reads.add(sl)
            writes.add(sl)
        elif is_indirect(d):
            barrier = True
        else:
            rs = regs_of(d)
            reads |= rs
            writes |= rs
        return reads, writes, barrier, unknown

    if mnem in RMW:
        d = ops[0].strip().lower() if ops else ""
        sl = slot_of(d)
        if sl:
            reads.add(sl)
            writes.add(sl)
        elif is_indirect(d):
            barrier = True
        else:
            rs = regs_of(d)
            reads |= rs
            writes |= rs
        return reads, writes, barrier, unknown

    if mnem in WRITEONLY:
        d = ops[0].strip().lower() if ops else ""
        if d in ("c", "cy"):
            return reads, writes, barrier, unknown
        sl = slot_of(d)
        if sl:
            writes.add(sl)
        elif is_indirect(d):
            barrier = True
        else:
            writes |= regs_of(d)
        return reads, writes, barrier, unknown

    if mnem in ("mul", "div"):
        reads |= {"a", "b"}
        writes |= {"a", "b"}
        return reads, writes, barrier, unknown

    if mnem == "movx":
        barrier = True  # 读写外部内存
        for op in ops:
            reads |= regs_of(op)
            writes |= regs_of(op)
        return reads, writes, barrier, unknown

    if mnem == "movc":
        writes.add("a")
        reads.add("a")
        reads |= {"dpl", "dph"}
        return reads, writes, barrier, unknown

    if mnem in ("xch", "xchd"):
        reads.add("a")
        writes.add("a")
        for op in ops:
            sl = slot_of(op)
            if sl:
                reads.add(sl)
                writes.add(sl)
            elif is_indirect(op):
                barrier = True
            else:
                reads |= regs_of(op)
                writes |= regs_of(op)
        return reads, writes, barrier, unknown

    if mnem == "push":
        if ops:
            reads |= regs_of(ops[0])
        return reads, writes, True, False

    if mnem == "pop":
        if ops:
            writes |= regs_of(ops[0])
        return reads, writes, True, False

    if mnem == "nop":
        return reads, writes, barrier, unknown

    if mnem == "setb":
        # 位操作（setb 0xb0.6 / setb c）：不改任何受跟踪寄存器。
        return reads, writes, barrier, unknown

    if mnem in FLOW:
        # `djnz rN,L` / `cjne a,rN,L` 等会读寄存器；调用按 ABI 读 a/b/dpl/dph。
        for op in ops:
            reads |= regs_of(op)
        if mnem in CALL:
            reads |= {"a", "b", "dpl", "dph"}
        return reads, writes, True, False

    # 未建模：可能读写任意寄存器/内存。
    return reads, writes, True, True


# --- 分析 -------------------------------------------------------------------
def _line_info(ln):
    code = ln.split(";", 1)[0]
    if not code.strip():
        return None
    if code.strip().startswith("."):
        return ("dir", "", [], ln)
    m = LABEL_RE.match(code)
    if m:
        return ("label", m.group(1), [], ln)
    m = INSN_RE.match(code)
    if m:
        ops = [x.strip() for x in m.group(2).split(",") if x.strip()]
        return ("insn", m.group(1).lower(), ops, ln)
    return ("other", "", [], ln)


def _func_starts(lines):
    return [i for i, ln in enumerate(lines) if GFUNC_RE.match(ln)]


def _func_span(starts, i, n):
    start, end = 0, n
    for b in starts:
        if b <= i:
            start = b
        else:
            end = b
            break
    return start, end


def _spx_moves(lines, start, end):
    """函数区间内是否有 `push`/`pop`（会让 `@spx<d>` 文本偏移失真）。

    后端帧槽相对 SPX：`push`/`pop`（压栈传参、DR28 搬运等）移动 SPX，使同一条**逻辑帧槽**
    在不同位置的**文本偏移不同**（例：`-0x10` 在 `push acc` 之后读作 `-0x11`）。按文本偏移判
    「从不被读」会误删这类 store（`ziglog` 的压栈传参即中招）。故这类函数**整体跳过**全函数
    死槽规则（块内 DSE 已把 push/pop 当屏障，安全）。
    只需 `push/pop`：序言/尾声的 `add/sub spx,#frame` 在首尾、不影响函数内偏移；调用者清理的
    `sub spx,#n` 必随 `push` 出现。
    """
    for j in range(start, end):
        code = lines[j].split(";", 1)[0].strip().lower()
        if code.startswith("push") or code.startswith("pop"):
            return True
    return False


def _whole_slot_dead(lines):
    """规则 1：帧槽在整个函数内**从不被读**（只写）-> 该 store 是死 store。

    比“槽从不出现”更强：一个槽被写多次但从不读时，**所有**这些 store 都可删。
    含 `push/pop/spx` 调整的函数因文本偏移不可靠而整体跳过（见 `_spx_moves`）。
    """
    starts = _func_starts(lines)
    delete = set()
    span_moves = {}
    for i, ln in enumerate(lines):
        sm = STORE_RE.match(ln)
        if not sm:
            continue
        slot = norm_slot(sm.group("off"))
        start, end = _func_span(starts, i, len(lines))
        if start not in span_moves:
            span_moves[start] = _spx_moves(lines, start, end)
        if span_moves[start]:
            continue
        read = False
        for j in range(start, end):
            if j == i or lines[j].lstrip().startswith(";"):
                continue
            if not any(norm_slot(m.group("off")) == slot for m in MEM_RE.finditer(lines[j])):
                continue
            # 该行对 @spx<slot> 的访问若不是「store 到同一槽」，就算读。
            smj = STORE_RE.match(lines[j])
            if smj is None or norm_slot(smj.group("off")) != slot:
                read = True
                break
        if not read:
            delete.add(i)
    return delete


def _whole_reg_dead(lines):
    """规则 3：`mov rN,X` 且 rN 在整个函数内从不被读 -> 死写。"""
    starts = _func_starts(lines)
    delete = set()
    for start in starts:
        _, end = _func_span(starts, start, len(lines))
        reads, unknown = set(), False
        for i in range(start, end):
            info = _line_info(lines[i])
            if not info or info[0] != "insn":
                continue
            r, _w, _b, u = classify(info[1], info[2], lines[i])
            reads |= r
            unknown = unknown or u
        if unknown:
            continue
        for i in range(start, end):
            info = _line_info(lines[i])
            if not info or info[0] != "insn":
                continue
            mnem, ops = info[1], info[2]
            if mnem != "mov" or len(ops) != 2:
                continue
            d = ops[0].strip().lower()
            rs = regs_of(d)
            if not rs or len(rs) != 1:
                continue
            reg = next(iter(rs))
            # 只处理 r0-r7：a/b/dpl/dph 可能是返回寄存器，不能仅凭“函数内未读”删除。
            if not re.match(r"^r[0-7]$", reg):
                continue
            if reg in reads:
                continue
            s = ops[1].strip().lower()
            # 源必须无副作用：寄存器 / 立即数 / 帧槽（避免删掉 SFR 读）。
            if not (is_imm(s) or regs_of(s) or slot_of(s)):
                continue
            delete.add(i)
    return delete


def _blocks(lines):
    """按 标签/指令边界/控制流 切基本块，返回 block -> [行号…]（仅 insn）。"""
    starts = _func_starts(lines)
    func = 0
    blocks = {}
    bid = 0
    for i, ln in enumerate(lines):
        if GFUNC_RE.match(ln):
            func += 1
            bid += 1
            continue
        info = _line_info(ln)
        if info is None:
            continue
        kind = info[0]
        if kind in ("dir", "label", "other"):
            bid += 1
            continue
        if kind != "insn":
            continue
        blocks.setdefault(bid, []).append(i)
        if info[1] in FLOW:
            bid += 1
    return blocks


def _block_dse(lines):
    """规则 2：块内下一条对 L 的访问若也是写，则该写为死写。"""
    delete = set()
    info_cache = {}
    for i, ln in enumerate(lines):
        info_cache[i] = _line_info(ln)
    for _bid, idxs in _blocks(lines).items():
        for pos, i in enumerate(idxs):
            info = info_cache[i]
            mnem, ops = info[1], info[2]
            if mnem != "mov" or len(ops) != 2:
                continue
            r, w, b, u = classify(mnem, ops, lines[i])
            if b or u or len(w) != 1:
                continue
            loc = next(iter(w))
            # 源必须无副作用（寄存器/立即数/帧槽）。
            s = ops[1].strip().lower()
            if not (is_imm(s) or regs_of(s) or slot_of(s)):
                continue
            verdict = "live"  # 块尾无覆盖 -> 保守保留
            for j in idxs[pos + 1:]:
                rj, wj, bj, uj = classify(
                    info_cache[j][1], info_cache[j][2], lines[j])
                if bj or uj:
                    verdict = "live"
                    break
                # 先看“读”：读-改-写指令（如 subb a,X）既读又写，其读意味着值仍活。
                if loc in rj:
                    verdict = "live"
                    break
                if loc in wj:
                    verdict = "dead"
                    break
            if verdict == "dead":
                delete.add(i)
    return delete


def optimize(lines):
    """反复应用规则直至稳定，最后删除 IR 提示与冷热标签注释。"""
    global TAGS
    TAGS = [m.group(1, 2, 3) for m in
            (TAG_RE.match(ln.rstrip("\n")) for ln in lines) if m]
    cur = list(lines)
    for _ in range(12):
        dead = set()
        dead |= _whole_slot_dead(cur)
        dead |= _whole_reg_dead(cur)
        dead |= _block_dse(cur)
        if not dead:
            break
        cur = [ln for i, ln in enumerate(cur) if i not in dead]
    # 删除 IR 提示与冷热标签注释（标签已记入 TAGS，供调用方使用）。
    cur = [ln for ln in cur
           if not TRACE_RE.match(ln.rstrip("\n")) and not TAG_RE.match(ln.rstrip("\n"))]
    return cur


# --- 自测 -------------------------------------------------------------------
def _self_test():
    # 1) 帧槽全函数不再出现 -> 删（原规则）。
    src = (
        "        add spx,#0x0003\n"
        "; v0 arg -> @spx0\n"
        "        mov a,dpl\n"
        "        mov @spx,a\n"
        "; v2 add v0 c -> @spx-1\n"
        "        add a,#0x03\n"
        "        mov @spx-0x1,a\n"
        "        mov dpl,a\n"
        "        sub spx,#0x0003\n"
        "        eret\n"
    )
    txt = "".join(optimize(src.splitlines(keepends=True)))
    assert "mov @spx,a" not in txt and "mov @spx-0x1,a" not in txt, txt
    assert "add a,#0x03" in txt and "mov dpl,a" in txt, txt
    assert ";" not in txt, txt

    # 1b) 同一帧槽被写多次但从不读 -> 全部删除。
    src = (
        "_f:\n"
        "        mov a,#0x01\n"
        "        mov @spx-0x1,a\n"
        "        mov a,#0x02\n"
        "        mov @spx-0x1,a\n"
        "        mov dpl,a\n"
        "        eret\n"
    )
    txt = "".join(optimize(src.splitlines(keepends=True)))
    assert "mov @spx-0x1,a" not in txt, txt

    # 2) 槽被后面读 -> 保留。
    src = (
        "_f:\n"
        "        mov a,#0x03\n"
        "        mov @spx-0x1,a\n"
        "        mov a,@spx-0x1\n"
        "        mov dpl,a\n"
    )
    txt = "".join(optimize(src.splitlines(keepends=True)))
    assert "mov @spx-0x1,a" in txt, txt

    # 3) 循环回边：store 在循环尾、read 在循环头 -> 必须保留。
    src = (
        "_f:\n"
        "        mov @spx-0x1,a\n"
        "        mov a,@spx-0x1\n"
        "        eret\n"
    )
    txt = "".join(optimize(src.splitlines(keepends=True)))
    assert "mov @spx-0x1,a" in txt, txt

    # 4) 块内死写：连续多次写同一槽，中间无读 -> 只留最后一次。
    src = (
        "_f:\n"
        "        add spx,#0x0001\n"
        "        mov a,#0x01\n"
        "        mov @spx-0x1,a\n"
        "        mov a,#0x02\n"
        "        mov @spx-0x1,a\n"
        "        mov a,#0x03\n"
        "        mov @spx-0x1,a\n"
        "        mov r7,@spx-0x1\n"
        "        mov dpl,r7\n"
        "        sub spx,#0x0001\n"
        "        eret\n"
    )
    txt = "".join(optimize(src.splitlines(keepends=True)))
    assert txt.count("mov @spx-0x1,a") == 1, txt
    assert "mov @spx-0x1,a" in txt, txt

    # 5) 全函数死寄存器写：r6 从不被读 -> 删 `mov r6,a`。
    src = (
        "_f:\n"
        "        mov a,dpl\n"
        "        mov r6,a\n"
        "        jz L1\n"
        "L1:\n"
        "        eret\n"
    )
    txt = "".join(optimize(src.splitlines(keepends=True)))
    assert "mov r6,a" not in txt, txt

    # 6) 寄存器被读 -> 保留。
    src = (
        "_f:\n"
        "        mov a,dpl\n"
        "        mov r6,a\n"
        "        mov a,r6\n"
        "        mov dpl,a\n"
        "        eret\n"
    )
    txt = "".join(optimize(src.splitlines(keepends=True)))
    assert "mov r6,a" in txt, txt

    # 7) 块内死寄存器写：下一条访问 r6 是写 -> 删。
    src = (
        "_f:\n"
        "        mov a,#0x01\n"
        "        mov r6,a\n"
        "        mov a,#0x02\n"
        "        mov r6,a\n"
        "        mov a,r6\n"
        "        mov dpl,a\n"
        "        eret\n"
    )
    txt = "".join(optimize(src.splitlines(keepends=True)))
    assert txt.count("mov r6,a") == 1, txt

    # 8) 屏障不跨越：push 之后不得删 store。
    src = (
        "_f:\n"
        "        mov a,#0x01\n"
        "        mov @spx-0x1,a\n"
        "        push a\n"
        "        mov a,#0x02\n"
        "        mov @spx-0x1,a\n"
        "        mov r7,@spx-0x1\n"
        "        pop a\n"
        "        mov dpl,r7\n"
        "        eret\n"
    )
    txt = "".join(optimize(src.splitlines(keepends=True)))
    assert txt.count("mov @spx-0x1,a") == 2, txt

    # 11) 含 push/pop 的函数跳过死槽规则（SPX 位移致文本偏移失真）-> store 须保留。
    src = (
        "_f:\n"
        "        push acc\n"
        "        mov a,#0x12\n"
        "        mov @spx-0x10,a\n"
        "        pop acc\n"
        "        eret\n"
    )
    txt = "".join(optimize(src.splitlines(keepends=True)))
    assert "mov @spx-0x10,a" in txt, txt

    # 9) 读-改-写要算“读”：store 后的 `mov a,@spx` 被 `subb a,#imm` 读过，须保留。
    src = (
        "_f:\n"
        "        mov a,#0x05\n"
        "        mov @spx-0x1,a\n"
        "        mov a,@spx-0x1\n"
        "        subb a,#0x01\n"
        "        mov dpl,a\n"
        "        eret\n"
    )
    txt = "".join(optimize(src.splitlines(keepends=True)))
    assert "mov a,@spx-0x1" in txt and "mov @spx-0x1,a" in txt, txt

    # 10) 间接寻址读地址寄存器：`mov r0,#sym` 被 `@r0` 用到，须保留。
    src = (
        "_f:\n"
        "        mov r0,#_buf\n"
        "        mov a,@r0\n"
        "        mov dpl,a\n"
        "        eret\n"
    )
    txt = "".join(optimize(src.splitlines(keepends=True)))
    assert "mov r0,#_buf" in txt, txt

    print("mcs_ir: self-test OK")


# --- 主流程 -----------------------------------------------------------------
def _write(path, lines):
    Path(path).write_text("".join(lines), encoding="utf-8", newline="")


def main(argv):
    if len(argv) > 1 and argv[1] == "--self-test":
        _self_test()
        return 0
    show_stats = "--stats" in argv
    files = [a for a in argv[1:] if not a.startswith("--")]
    for p in files:
        path = Path(p)
        lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
        before = sum(1 for ln in lines if ln.strip() and not ln.lstrip().startswith(";")
                     and not ln.lstrip().startswith(".") and not LABEL_RE.match(ln))
        out = optimize(lines)
        after = sum(1 for ln in out if ln.strip() and not ln.lstrip().startswith(";")
                    and not ln.lstrip().startswith(".") and not LABEL_RE.match(ln))
        _write(path, out)
        if show_stats:
            print(f"mcs_ir: {path.name}: 指令 {before} -> {after}（省 {before - after}）")
            from collections import Counter
            cnt = Counter(t for _k, _n, t in TAGS)
            summary = " ".join(f"{t}x{c}" for t, c in sorted(cnt.items())) or "（无）"
            print(f"       标签：{summary}（放置/O 等级由后端应用；本工具消费注释后删除）")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
