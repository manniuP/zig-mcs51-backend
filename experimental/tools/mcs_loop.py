#!/usr/bin/env python3
"""mcs_loop.py —— 构建层：把后端生成的「计数 while 循环」改写为「下行计数 + DJNZ」。

背景：MCS 后端把循环归纳变量 `i`（16 位）放在帧槽里，每轮做
「拷 i 到临时槽(4) + clr/subb/subb/clr/addc(6) + jnz(3)」的 16 位比较，再加
「回跳 ejmp(3)」和「i++ 的 14 条帧搬运」——data 读循环每轮 43 周期里约 34 是开销。
本工具识别该固定形状，改成两个字节寄存器的**下行计数**，用 `djnz Rn,rel` 收尾：

    mov  rHi,#hiAdj        ; DJNZ 先减后判，装载值即总次数
    mov  rLo,#loN
  Lc:                       ; 循环头（原条件块被删）
    <body>                  ; 原体，去掉 i++
    djnz rLo,Lc             ; 低字节
    djnz rHi,Lc             ; 低字节减到 0 时减高字节；高字节到 0 退出
  Lexit:

计数正确性：设 N=hi*256+lo。`rHi=hi+(lo>0)`、`rLo=lo`，则循环体恰执行 N 次
（lo>0：lo+(hi)*256；lo=0：hi*256）。N=500 → rLo=0xF4、rHi=2。

安全约束（不满足则跳过该循环）：
  * 条件是**编译期常量**比较（`subb a,#lo` / `subb a,#hi`），1 ≤ N ≤ 0xFFFF；
  * body 内**无调用**（ecall/lcall/acall，避免被调函数踩寄存器）；
  * 归纳变量槽 i0/i1 只出现在条件块与自增块里（body 不引用）；
  * 所选计数器寄存器在**整个文件**里都未被使用（含 @rN 与 R0–R7）。
  * **默认关闭**：设 `MCS_LOOP=1` 才改写。带中断的程序若 ISR 会踩所选寄存器，
    请在编译期改用别的寄存器或关闭本优化（见 docs/22）。

用法：
  python tools/mcs_loop.py <x.asm>     # 就地改写（通常由 xmake postprocess 调用）
  python tools/mcs_loop.py --self-test
"""
import os
import re
import sys

SPX = r"@spx(?:-0x[0-9a-fA-F]+)?"
RE_COND_LABEL = re.compile(r"^[A-Za-z_]\w*:\s*$")
RE_LABEL = re.compile(r"^([A-Za-z_]\w*):\s*$")
RE_A_SPX = re.compile(r"mov\s+a,\s*(%s)" % SPX)
RE_SPX_A = re.compile(r"mov\s+(%s),\s*a" % SPX)
RE_SPX_IMM = re.compile(r"mov\s+(%s),\s*#(0x[0-9a-fA-F]+)" % SPX)
RE_SUBB = re.compile(r"subb\s+a,\s*#(0x[0-9a-fA-F]+)")
RE_JNZ = re.compile(r"jnz\s+([A-Za-z_]\w*)")
RE_EJMP = re.compile(r"ejmp\s+([A-Za-z_]\w*)")
RE_ADD1 = re.compile(r"add\s+a,\s*#0x0*1\b")
RE_ADDC0 = re.compile(r"addc\s+a,\s*#0x0*0\b")
RE_CALL = re.compile(r"\b(ecall|lcall|acall)\b")
RE_REG = re.compile(r"\br([0-7])\b")


def used_registers(text):
    return sorted({int(m.group(1)) for m in RE_REG.finditer(text)})


def parse_cond(ls, i):
    """识别条件块：返回 dict 或 None。ls[i] 为条件标签行。"""
    j = i + 1
    try:
        m = RE_A_SPX.fullmatch(ls[j])
        i0 = m.group(1)
        j += 1
        m = RE_SPX_A.fullmatch(ls[j])
        t0 = m.group(1)
        j += 1
        m = RE_A_SPX.fullmatch(ls[j])
        i1 = m.group(1)
        j += 1
        m = RE_SPX_A.fullmatch(ls[j])
        t1 = m.group(1)
        j += 1
        if ls[j] != "clr cy":
            return None
        j += 1
        if ls[j] != "mov a,%s" % t0:
            return None
        j += 1
        m = RE_SUBB.fullmatch(ls[j])
        lo = int(m.group(1), 16)
        j += 1
        if ls[j] != "mov a,%s" % t1:
            return None
        j += 1
        m = RE_SUBB.fullmatch(ls[j])
        hi = int(m.group(1), 16)
        j += 1
        if ls[j] != "clr a":
            return None
        j += 1
        if not RE_ADDC0.fullmatch(ls[j]):
            return None
        j += 1
        m = RE_JNZ.fullmatch(ls[j])
        body = m.group(1)
        j += 1
        m = RE_EJMP.fullmatch(ls[j])
        exit_lbl = m.group(1)
        j += 1
        if not RE_LABEL.fullmatch(ls[j]) or RE_LABEL.fullmatch(ls[j]).group(1) != body:
            return None
    except (AttributeError, IndexError):
        return None
    return {"i0": i0, "i1": i1, "cond": RE_LABEL.fullmatch(ls[i]).group(1),
            "body": body, "exit": exit_lbl, "body_idx": j, "lo": lo, "hi": hi}


def parse_incr(ls, i):
    """ls[i..i+13] 应为 i++ 块；返回 (i0,i1) 或 None。"""
    try:
        m0 = RE_A_SPX.fullmatch(ls[i])
        i0 = m0.group(1); j = i + 1
        u0 = RE_SPX_A.fullmatch(ls[j]).group(1); j += 1
        m1 = RE_A_SPX.fullmatch(ls[j])
        i1 = m1.group(1); j += 1
        u1 = RE_SPX_A.fullmatch(ls[j]).group(1); j += 1
        if ls[j] != "mov a,%s" % u0:
            return None
        j += 1
        if not RE_ADD1.fullmatch(ls[j]):
            return None
        j += 1
        u2 = RE_SPX_A.fullmatch(ls[j]).group(1); j += 1
        if ls[j] != "mov a,%s" % u1:
            return None
        j += 1
        if not RE_ADDC0.fullmatch(ls[j]):
            return None
        j += 1
        u3 = RE_SPX_A.fullmatch(ls[j]).group(1); j += 1
        if ls[j] != "mov a,%s" % u2:
            return None
        j += 1
        if ls[j] != "mov %s,a" % i0:
            return None
        j += 1
        if ls[j] != "mov a,%s" % u3:
            return None
        j += 1
        if ls[j] != "mov %s,a" % i1:
            return None
    except AttributeError:
        return None
    return (i0, i1)


def _frame(op):
    return re.fullmatch(SPX, op) is not None


def rewrite_body(body, free):
    """把「帧溢出式」读-改-写体折叠为直接访存形式（轻量寄存器/访存分配）。

    识别后端固定形状 `mov a,S; mov T,a; <读D>; mov U,a; mov a,T; mov rQ,U; add a,rQ; mov S,a`
    （S/T/U 帧槽），改写为 `mov a,S; <用合适的寻址加 D>; mov S,a`。返回 (新体, 使用的临时寄存器或 None)。
    """
    st = [l.strip() for l in body]
    if not body:
        return body, None
    # 跳过开头的标签行（body 区包含入口标签）
    k = 0
    while k < len(st) and RE_LABEL.fullmatch(st[k]):
        k += 1
    head = body[:k]
    body = body[k:]
    st = st[k:]
    if not body:
        return head, None
    indent = body[0][:len(body[0]) - len(body[0].lstrip())]
    nl = "\n" if body[-1].endswith("\n") else ""

    def mk(ins):
        return head + [indent + s + nl for s in ins]

    def f(g):
        return g is not None and _frame(g.group(1))

    # --- data：8 行，直接寻址读 ---
    if len(st) == 8:
        m = (re.fullmatch(r"mov a,(%s)" % SPX, st[0]),
             re.fullmatch(r"mov (%s),a" % SPX, st[1]),
             re.fullmatch(r"mov a,([^@#][^,]*|\d\w*)", st[2]),
             re.fullmatch(r"mov (%s),a" % SPX, st[3]),
             re.fullmatch(r"mov a,(%s)" % SPX, st[4]),
             re.fullmatch(r"mov r\d,(%s)" % SPX, st[5]),
             re.fullmatch(r"add a,r\d", st[6]),
             re.fullmatch(r"mov (%s),a" % SPX, st[7]))
        if f(m[0]) and f(m[1]) and m[2] and f(m[3]) and f(m[4]) and f(m[5]) and m[6] and f(m[7]):
            S, T, D, U = m[0].group(1), m[1].group(1), m[2].group(1), m[3].group(1)
            if m[4].group(1) == T and m[5].group(1) == U and m[7].group(1) == S \
                    and D not in (S, T, U, "a"):
                return mk(["mov a,%s" % S, "add a,%s" % D, "mov %s,a" % S]), None

    # --- idata：9 行 r0 间接 / edata：9 行 dptr;movx ---
    if len(st) == 9 and f(re.fullmatch(r"mov a,(%s)" % SPX, st[0])) \
            and f(re.fullmatch(r"mov (%s),a" % SPX, st[1])) \
            and f(re.fullmatch(r"mov (%s),a" % SPX, st[4])) \
            and f(re.fullmatch(r"mov a,(%s)" % SPX, st[5])) \
            and re.fullmatch(r"mov r\d,(%s)" % SPX, st[6]) \
            and re.fullmatch(r"add a,r\d", st[7]) \
            and f(re.fullmatch(r"mov (%s),a" % SPX, st[8])):
        S = re.fullmatch(r"mov a,(%s)" % SPX, st[0]).group(1)
        T = re.fullmatch(r"mov (%s),a" % SPX, st[1]).group(1)
        U = re.fullmatch(r"mov (%s),a" % SPX, st[4]).group(1)
        if re.fullmatch(r"mov a,(%s)" % SPX, st[5]).group(1) == T \
                and re.fullmatch(r"mov r\d,(%s)" % SPX, st[6]).group(1) == U \
                and re.fullmatch(r"mov (%s),a" % SPX, st[8]).group(1) == S:
            mi = re.fullmatch(r"mov r0,(.+)", st[2])
            me = re.fullmatch(r"mov dptr,(.+)", st[2])
            if mi and st[3] == "mov a,@r0":
                return mk(["mov a,%s" % S, "mov r0,%s" % mi.group(1),
                           "add a,@r0", "mov %s,a" % S]), None
            if me and st[3] == "movx a,@dptr" and free:
                rp = free[0]
                return mk(["mov a,%s" % S, "mov r%d,a" % rp, "mov dptr,%s" % me.group(1),
                           "movx a,@dptr", "add a,r%d" % rp, "mov %s,a" % S]), rp

    # --- xdata：10 行 dptr+dpxl+@dpx ---
    if len(st) == 10 and f(re.fullmatch(r"mov a,(%s)" % SPX, st[0])) \
            and f(re.fullmatch(r"mov (%s),a" % SPX, st[1])) \
            and re.fullmatch(r"mov dptr,(.+)", st[2]) \
            and re.fullmatch(r"mov dpxl,(.+)", st[3]) \
            and st[4] == "mov a,@dpx" \
            and f(re.fullmatch(r"mov (%s),a" % SPX, st[5])) \
            and f(re.fullmatch(r"mov a,(%s)" % SPX, st[6])) \
            and re.fullmatch(r"mov r\d,(%s)" % SPX, st[7]) \
            and re.fullmatch(r"add a,r\d", st[8]) \
            and f(re.fullmatch(r"mov (%s),a" % SPX, st[9])) and free:
        S = re.fullmatch(r"mov a,(%s)" % SPX, st[0]).group(1)
        T = re.fullmatch(r"mov (%s),a" % SPX, st[1]).group(1)
        U = re.fullmatch(r"mov (%s),a" % SPX, st[5]).group(1)
        if re.fullmatch(r"mov a,(%s)" % SPX, st[6]).group(1) == T \
                and re.fullmatch(r"mov r\d,(%s)" % SPX, st[7]).group(1) == U \
                and re.fullmatch(r"mov (%s),a" % SPX, st[9]).group(1) == S:
            rp = free[0]
            return mk(["mov a,%s" % S, "mov r%d,a" % rp,
                       "mov dptr,%s" % re.fullmatch(r"mov dptr,(.+)", st[2]).group(1),
                       "mov dpxl,%s" % re.fullmatch(r"mov dpxl,(.+)", st[3]).group(1),
                       "mov a,@dpx", "add a,r%d" % rp, "mov %s,a" % S]), rp
    return head + body, None


def try_loop(lines, cond_idx, regs, stats, defs, free):
    st = [x.strip() for x in lines]
    info = parse_cond(st, cond_idx)
    if not info:
        return None
    N = info["lo"] + (info["hi"] << 8)
    if N < 1 or N > 0xFFFF:
        return None
    if info["i0"] == info["i1"]:
        return None
    # 自增块 + 回跳 ejmp（body 中最后一段）
    body_e = None
    for e in range(info["body_idx"] + 1, len(st)):
        m = RE_EJMP.fullmatch(st[e])
        if not m:
            continue
        inc = parse_incr(st, e - 14)
        if inc and inc == (info["i0"], info["i1"]):
            body_e = e
            break
    if body_e is None:
        return None
    body_text = "\n".join(lines[info["body_idx"] + 1:body_e - 14])
    has_call = RE_CALL.search(body_text) is not None
    # i0/i1 不得在 body 中出现（词边界，避免 @spx-0x1 命中 @spx-0x11）
    if _mentions(body_text, info["i0"]) or _mentions(body_text, info["i1"]):
        return None
    text = "\n".join(lines)
    # 函数范围（下一个全局标签起）
    func_end = len(st)
    for k in range(cond_idx + 1, len(st)):
        if re.match(r"^_[A-Za-z]\w*:\s*$", st[k]):
            func_end = k
            break
    # 循环后不得再引用 i（否则删掉自增会破坏后续使用）
    after = "\n".join(lines[body_e + 1:func_end])
    if _mentions(after, info["i0"]) or _mentions(after, info["i1"]):
        return None
    # i 必须在外层初始化为 0（否则计数 ≠ N）
    if not _init_zero_before(st, cond_idx, info["i0"], info["i1"]):
        return None
    indent = lines[body_e][:len(lines[body_e]) - len(lines[body_e].lstrip())]
    nl = "\n" if lines[body_e].endswith("\n") else ""
    hi_adj = info["hi"] + (1 if info["lo"] else 0)
    body = lines[info["body_idx"]:body_e - 14]
    if not has_call:
        body_free = [r for r in (free or []) if r not in (regs or ())]
        body, _ = rewrite_body(body, body_free)
    if has_call or not regs:
        # body 含调用：寄存器会被被调函数踩 -> 用 DSEG 直接字节计数器（DJNZ dir8），
        # 调用不影响；缺点是多占 2 字节 data、同循环不可重入。
        sym = "_mcsloop_%d" % (len(defs) + 1)
        defs.append(sym)
        init = ["%smov %s,#0x%02x%s" % (indent, sym, info["lo"], nl),
                "%smov %s+1,#0x%02x%s" % (indent, sym, hi_adj, nl)]
        pair = ["%sdjnz %s,%s%s" % (indent, sym, info["cond"], nl),
                "%sdjnz %s+1,%s%s" % (indent, sym, info["cond"], nl)]
        tag = sym
    else:
        rlo, rhi = regs
        init = ["%smov r%d,#0x%02x%s" % (indent, rhi, hi_adj, nl),
                "%smov r%d,#0x%02x%s" % (indent, rlo, info["lo"], nl)]
        pair = ["%sdjnz r%d,%s%s" % (indent, rlo, info["cond"], nl),
                "%sdjnz r%d,%s%s" % (indent, rhi, info["cond"], nl)]
        tag = "r%d/r%d" % (rlo, rhi)
    stats.append((info["cond"], N, tag))
    return lines[:cond_idx] + init + [lines[cond_idx]] + body + pair + lines[body_e + 1:]


def _mentions(text, slot):
    """slot（如 @spx-0x1）是否作为独立记号出现（避免 @spx-0x11 误命中）。"""
    return re.search(re.escape(slot) + r"(?![0-9a-fA-F-])", text) is not None


def _init_zero_before(st, cond_idx, i0, i1):
    """确认 i0/i1 在循环前被 0 初始化（最近的前置 mov a,#imm 为 0）。"""
    for slot in (i0, i1):
        write = None
        for k in range(cond_idx - 1, -1, -1):
            if st[k] == "mov %s,a" % slot:
                write = k
                break
        if write is None:
            return False
        imm = None
        for k in range(write - 1, -1, -1):
            m = re.fullmatch(r"mov a,#(0x[0-9a-fA-F]+)", st[k])
            if m:
                imm = int(m.group(1), 16)
                break
        if imm != 0:
            return False
    return True


def optimize(text, regs, free=None):
    lines = text.splitlines(keepends=True)
    stats = []
    defs = []
    out = lines
    i = 0
    while i < len(out):
        if RE_COND_LABEL.match(out[i].strip()):
            r = try_loop(out, i, regs, stats, defs, free or [])
            if r is not None:
                out = r
                i += 0  # 重新扫描当前位置（已换新内容）
                continue
        i += 1
    if defs:
        out.append("\t.area DSEG    (DATA)\n")
        for sym in defs:
            out.append("\t.globl %s\n%s:\n\t.ds 2\n" % (sym, sym))
    return "".join(out), stats


def process_file(path):
    with open(path, encoding="utf-8") as fp:
        src = fp.read()
    used = set(used_registers(src))
    free = [r for r in (7, 6, 5, 4, 3, 2, 1, 0) if r not in used]
    regs = (free[1], free[0]) if len(free) >= 2 else None
    out, stats = optimize(src, regs, free)
    if stats:
        with open(path, "w", encoding="utf-8", newline="\n") as fp:
            fp.write(out)
    return len(stats), stats


def self_test():
    src = """_f:
        add spx,#0x0014
        mov a,#0x00
        mov @spx-0x1,a
        mov @spx-0x2,a
L_2:
        mov a,@spx-0x1
        mov @spx-0x5,a
        mov a,@spx-0x2
        mov @spx-0x6,a
        clr cy
        mov a,@spx-0x5
        subb a,#0xf4
        mov a,@spx-0x6
        subb a,#0x01
        clr a
        addc a,#0x00
        jnz L_6
        ejmp L_7
L_6:
        mov a,_v
        mov @spx-0x9,a
        mov a,@spx-0x1
        mov @spx-0xb,a
        mov a,@spx-0x2
        mov @spx-0xc,a
        mov a,@spx-0xb
        add a,#0x01
        mov @spx-0xd,a
        mov a,@spx-0xc
        addc a,#0x00
        mov @spx-0xe,a
        mov a,@spx-0xd
        mov @spx-0x1,a
        mov a,@spx-0xe
        mov @spx-0x2,a
        ejmp L_5
L_7:
        ejmp L_1
L_5:
        ejmp L_2
L_1:
        eret
"""
    out, stats = optimize(src, (5, 4))
    assert stats == [("L_2", 500, "r5/r4")], stats
    assert "djnz r5,L_2" in out and "djnz r4,L_2" in out, out
    assert "mov r4,#0x02" in out and "mov r5,#0xf4" in out, out
    # 含调用的 body -> DSEG 直接字节计数器（DJNZ dir8）
    src2 = src.replace("        mov a,_v\n",
                       "        ecall _g\n        mov a,_v\n")
    out2, stats2 = optimize(src2, (5, 4))
    assert stats2 and stats2[0][2].startswith("_mcsloop_"), stats2
    assert "djnz _mcsloop_1,L_2" in out2, out2
    assert "\t.area DSEG" in out2 and "_mcsloop_1:" in out2, out2
    assert "mov _mcsloop_1,#0xf4" in out2 and "mov _mcsloop_1+1,#0x02" in out2, out2
    # 帧溢出体折叠（data 直接寻址）
    body = ["        mov a,@spx\n", "        mov @spx-0x8,a\n",
            "        mov a,_v\n", "        mov @spx-0x9,a\n",
            "        mov a,@spx-0x8\n", "        mov r7,@spx-0x9\n",
            "        add a,r7\n", "        mov @spx,a\n"]
    nb, _ = rewrite_body(body, [])
    assert [x.strip() for x in nb] == ["mov a,@spx", "add a,_v", "mov @spx,a"], nb
    # 迭代次数模拟
    def sim(N, lo=None, hi=None):
        lo = N & 0xFF if lo is None else lo
        hi = (N >> 8) + (1 if lo else 0) if hi is None else hi
        n = 0
        while True:
            n += 1
            lo = (lo - 1) & 0xFF
            if lo != 0:
                continue
            hi = (hi - 1) & 0xFF
            if hi != 0:
                continue
            return n
    for N in (1, 2, 100, 255, 256, 257, 500, 511, 512, 1000, 65535):
        assert sim(N) == N, (N, sim(N))
    print("mcs_loop --self-test: OK（改写 + 计数模拟 12/12）")
    return 0


def main():
    if "--self-test" in sys.argv:
        return self_test()
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    if not os.getenv("MCS_LOOP") or os.getenv("MCS_LOOP") == "0":
        # 未启用：静默跳过（构建脚本可无条件调用）
        return 0
    path = sys.argv[1]
    n, stats = process_file(path)
    if n:
        for cond, N, tag in stats:
            print("mcs_loop: %s N=%d -> djnz %s" % (cond, N, tag))
    return 0


if __name__ == "__main__":
    sys.exit(main())
