#!/usr/bin/env python3
"""mcs_dce.py —— MCS 工具链的**构建层死代码回收**（未使用函数/变量）。

背景（`docs/交接-2026-09-15.md` §5.10）：
    Zig 源码级的未用函数/变量后端已自动剔除；但 **sdld 不回收未用段**，C（SDCC）与
    Zig 的代码又都进**单一 CSEG**，所以「库模块里没被引用的函数/变量」会白占 Flash
    （例如 cmd 里 `_cobs_encode`、`_cobs_finish` 等）。重编编译器也解决不了 C 侧。

做法：对**所有 .asm**（C 的 SDCC asm + Zig 的 asm）一起做**跨模块可达性分析**：
    - 以 `--keep` 的模块（入口：含 `_main`/中断向量表/crt0）里的**全部定义与引用**为根；
    - 沿「定义块 → 其文本里引用到的全局符号」BFS；
    - 删掉**未被可达**的全局符号块（函数/变量）及其 `.globl`。
然后在 `sdas` 之前就地改写 .asm；只删「整块、按名字可证明无人引用」的东西，局部标号
随所在块一起保留，语义不变。

用法：
    python mcs_dce.py --keep main.asm lib1.asm lib2.asm lib3.asm   # 就地改写 lib*
    python mcs_dce.py --keep main.asm --root _isr lib.asm
    python mcs_dce.py --stats --keep main.asm lib.asm              # 打印回收统计
    python mcs_dce.py --self-test

说明：
    - 只按**全局符号名**（`^_?[A-Za-z_][A-Za-z0-9_]*:` 顶格标签）分块；局部标号（如 SDCC 的
      `00130$`）不参与，随块保留。
    - `.globl` 不算引用（它只是声明）；被删符号的 `.globl` 一并删除。
    - 未初始化的数据符号按块删除；**已初始化全局的初始化代码在 GSINIT 里**，暂不处理
      （其符号会被 GSINIT 引用而保留，属已知限制）。
"""

import argparse
import re
import sys
import tempfile
from pathlib import Path

# 顶格全局标签：`_name:` / `name:`（局部标号以数字或 `$` 结尾，不匹配）。
GLABEL_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):")
# `.globl _sym`
GLOBL_RE = re.compile(r"^\s*\.globl\s+([A-Za-z_][A-Za-z0-9_]*)\s*$")
# 删块时必须保留的**结构指令**（否则后续代码会落错段/基址）。
KEEP_RE = re.compile(r"^\s*\.(area|org|module|optsdcc|even|page|list|nlist|radix|end)\b")
# 一般标识符
IDENT_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def strip_comment(line: str) -> str:
    i = line.find(";")
    return line if i < 0 else line[:i]


class Block:
    __slots__ = ("sym", "start", "end", "refs")

    def __init__(self, sym, start):
        self.sym = sym
        self.start = start
        self.end = None      # 开区间，指向下一块起始行
        self.refs = set()


def parse_lines(lines):
    """返回 (blocks, preamble_end)；preamble 为第一个全局标签之前的行。"""
    blocks = []
    cur = None
    for idx, line in enumerate(lines):
        m = GLABEL_RE.match(line)
        if m:
            if cur is not None:
                cur.end = idx
            cur = Block(m.group(1), idx)
            blocks.append(cur)
    if cur is not None:
        cur.end = len(lines)
    preamble_end = blocks[0].start if blocks else len(lines)
    return blocks, preamble_end


def collect_refs(lines, blocks, all_syms):
    for b in blocks:
        seg = lines[b.start:b.end]
        ids = set()
        for ln in seg:
            for tok in IDENT_RE.findall(strip_comment(ln)):
                ids.add(tok)
        ids.discard(b.sym)
        b.refs = {s for s in ids if s in all_syms}


def dce(files, keep_files, roots, stats=False):
    """files: {path: lines}；keep_files: set(path)；返回 {path: new_lines}。"""
    # 1) 全部全局符号 -> 定义块
    defblock = {}
    per_file_blocks = {}
    for path, lines in files.items():
        blocks, pre = parse_lines(lines)
        per_file_blocks[path] = (blocks, pre)
    all_syms = set()
    for path, (blocks, _) in per_file_blocks.items():
        for b in blocks:
            all_syms.add(b.sym)
    for path, (blocks, _) in per_file_blocks.items():
        for b in blocks:
            if b.sym in defblock:
                print(f"mcs_dce: warning: duplicate symbol {b.sym} in {path}", file=sys.stderr)
            defblock.setdefault(b.sym, (path, b))
    # 2) 引用
    for path, (blocks, _) in per_file_blocks.items():
        collect_refs(files[path], blocks, all_syms)

    # 3) 根：keep 文件的全部定义 + 其文本引用 + --root
    work = list(roots)
    for path in keep_files:
        blocks, pre = per_file_blocks[path]
        work.extend(b.sym for b in blocks)
        text = "".join(strip_comment(l) for l in files[path])
        work.extend(t for t in IDENT_RE.findall(text) if t in all_syms)

    # 4) BFS
    reachable = set()
    stack = list(work)
    while stack:
        s = stack.pop()
        if s in reachable or s not in defblock:
            continue
        reachable.add(s)
        _, b = defblock[s]
        for r in b.refs:
            if r not in reachable:
                stack.append(r)

    # 5) 删除：非 keep 文件里未可达的块
    removed_syms = set()
    out = {}
    for path, lines in files.items():
        if path in keep_files:
            out[path] = lines
            continue
        blocks, pre = per_file_blocks[path]
        drop = [False] * len(lines)
        nrem = 0
        nbytes = 0
        for b in blocks:
            if b.sym not in reachable:
                for i in range(b.start, b.end):
                    if not KEEP_RE.match(lines[i]):
                        drop[i] = True
                removed_syms.add(b.sym)
                nrem += 1
                nbytes += b.end - b.start
        new = [ln for i, ln in enumerate(lines) if not drop[i]]
        # 删 .globl（本文件定义的、已删符号）
        new = [ln for ln in new
               if not (GLOBL_RE.match(ln) and GLOBL_RE.match(ln).group(1) in removed_syms)]
        out[path] = new
        if stats and nrem:
            names = ", ".join(b.sym for b in blocks if b.sym not in reachable)
            print(f"  {Path(path).name}: 删 {nrem} 块 / {nbytes} 行: {names}")

    if stats:
        print(f"mcs_dce: 可达 {len(reachable)} 符号，删 {len(removed_syms)} 块")
    return out


def run(files_list, keep_list, roots, stats):
    keep = set(keep_list)
    allpaths = list(dict.fromkeys(list(files_list) + list(keep_list)))  # 去重保序
    files = {f: Path(f).read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)
             for f in allpaths}
    out = dce(files, keep, roots, stats=stats)
    for path, lines in out.items():
        Path(path).write_text("".join(lines), encoding="utf-8", newline="")


# ---------------------------------------------------------------- self-test
SELF_KEEP = """\
	.module keep
	.globl _main
	.area CSEG    (CODE)
_main:
	ecall _used
	.ejmp _used
__interrupt_vect:
	ejmp _isr
_ok:
	.ds 1
"""

SELF_LIB = """\
	.module lib
	.globl _used
	.globl _unused
	.globl _unused_data
	.area CSEG    (CODE)
_used:
	ecall _helper
	mov	dptr,#_used_data
	ret
_helper:
	ret
_unused:
	ecall _helper2
	ret
_helper2:
	ret
	.area XSEG    (XDATA)
_used_data:
	.ds 2
_unused_data:
	.ds 4
"""


def self_test():
    with tempfile.TemporaryDirectory() as d:
        kp = Path(d) / "keep.asm"
        lb = Path(d) / "lib.asm"
        kp.write_text(SELF_KEEP, encoding="utf-8")
        lb.write_text(SELF_LIB, encoding="utf-8")
        run([str(kp), str(lb)], [str(kp)], [], stats=False)
        txt = lb.read_text(encoding="utf-8")
        ok = True

        def chk(name, cond):
            nonlocal ok
            if not cond:
                print(f"  FAIL: {name}")
                ok = False

        chk("_used 保留", "_used:" in txt)
        chk("_helper 保留", "_helper:" in txt)
        chk("_used_data 保留", "_used_data:" in txt)
        chk("_unused 删除", "_unused:" not in txt)
        chk("_helper2 删除", "_helper2:" not in txt)
        chk("_unused_data 删除", "_unused_data:" not in txt)
        chk("_unused .globl 删除", ".globl _unused\n" not in txt and ".globl _unused " not in txt)
        chk("keep 文件原样", kp.read_text(encoding="utf-8") == SELF_KEEP)
        print("mcs_dce self-test: " + ("ALL OK" if ok else "FAIL"))
        return 0 if ok else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description="构建层死代码回收（跨模块可达性）")
    ap.add_argument("files", nargs="*", help="参与的 .asm（就地改写非 --keep 的）")
    ap.add_argument("--keep", action="append", default=[], help="入口模块（全部符号/引用为根），可多次")
    ap.add_argument("--root", action="append", default=[], help="额外根符号，可多次")
    ap.add_argument("--stats", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()
    if not args.files:
        ap.error("需要至少一个 .asm")
    if not args.keep:
        ap.error("需要至少一个 --keep（入口模块），否则会删光")
    run(args.files, args.keep, list(args.root), args.stats)
    return 0


if __name__ == "__main__":
    sys.exit(main())
