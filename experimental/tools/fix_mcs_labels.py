#!/usr/bin/env python3
"""重命名 MCS 后端产出的函数内局部标签 `L<number>`，消除跨函数重名。

背景（见 docs/07-调试笔记）：
    Zig MCS 后端的 `Gen.next_label` 是**每个函数**从 0 重新编号
    （`compiler/src/codegen/mcs/CodeGen.zig` 的 `generate()` 里新建 `Gen`），
    而 `Mir` 把它们直接输出为**文件级**全局标签 `L1:`、`L2:`……
    于是同一个 `.asm` 里只要有两个含分支的函数，就会撞标签；
    `sdas251` 报 `<m> multiple definitions` + `<p> phase error`。

    彻底修法是给标签加函数前缀，但那要重编 `zig.exe`（当前不可行，见 docs/07）。
    本脚本在**构建层**做等价的后处理：按函数边界给每个函数内的 `L<n>` 加唯一前缀，
    从而允许一个 `.asm` 内存在多个含分支的函数。

函数边界识别（按优先级）：
    1. `.globl <sym>` 指令；
    2. 行首的全局标签 `name:`（`name` 不是 `L<digits>`）。

用法：
    python fix_mcs_labels.py <file.asm>            # 就地改写
    python fix_mcs_labels.py <in.asm> -o <out.asm> # 输出到别处
    python fix_mcs_labels.py --check <file.asm>    # 只检查是否有跨函数重名，不写回
"""

import argparse
import re
import sys
from pathlib import Path

# 局部标签：独立的 `L` + 十进制数字（前后都不是标识符字符）。
LOCAL_LABEL = re.compile(r"(?<![A-Za-z0-9_])L(\d+)(?![0-9])")
GLOBL_DIRECTIVE = re.compile(r"^\s*\.globl\s+(\S+)")
GLOBAL_LABEL = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):")


def _sanitize_prefix(sym: str) -> str:
    """把符号名变成合法的标签片段（去掉前导下划线，非法字符换下划线）。"""
    return re.sub(r"[^A-Za-z0-9_]", "_", sym.lstrip("_")) or "fn"


def rewrite(text: str, check_only: bool = False):
    """按函数给 `L<n>` 加前缀。返回 (新文本, 重命名次数, 函数数)。"""
    lines = text.splitlines(keepends=True)
    out = []
    prefix = None
    seen_prefixes = set()
    renames = 0
    functions = 0

    for line in lines:
        # 注释从 `;` 开始，语义部分与注释分开处理。
        code, sep, comment = line.partition(";")

        # 先判断是否进入新函数（只看代码部分）。
        new_prefix = None
        m = GLOBL_DIRECTIVE.match(code)
        if m:
            new_prefix = _sanitize_prefix(m.group(1))
        else:
            m = GLOBAL_LABEL.match(code)
            if m and not re.fullmatch(r"L\d+", m.group(1)):
                new_prefix = _sanitize_prefix(m.group(1))
        if new_prefix is not None and new_prefix != prefix:
            prefix = new_prefix
            functions += 1
            seen_prefixes.add(prefix)

        if prefix and "L" in code:
            def _sub(mm):
                nonlocal renames
                renames += 1
                return f"L_{prefix}_{mm.group(1)}"

            code = LOCAL_LABEL.sub(_sub, code)

        out.append(code + sep + comment)

    return "".join(out), renames, functions


def find_duplicates(text: str):
    """返回在文件内被定义超过一次的局部标签名（用于 --check）。"""
    defs = {}
    prefix = None
    for line in text.splitlines():
        code = line.partition(";")[0]
        m = GLOBL_DIRECTIVE.match(code)
        if m:
            prefix = _sanitize_prefix(m.group(1))
        else:
            m = GLOBAL_LABEL.match(code)
            if m and not re.fullmatch(r"L\d+", m.group(1)):
                prefix = _sanitize_prefix(m.group(1))
        for name in re.findall(r"(?<![A-Za-z0-9_])L\d+(?![0-9])", code):
            defs.setdefault(name, []).append(prefix)
    return {k: v for k, v in defs.items() if len(v) > 1}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="重命名 MCS 后端产出的函数内局部标签 L<n>。")
    ap.add_argument("asm", help="输入的 .asm 文件")
    ap.add_argument("-o", "--out", help="输出文件（默认就地改写）")
    ap.add_argument("--check", action="store_true",
                    help="只报告跨函数重名标签，不写回")
    args = ap.parse_args(argv)

    path = Path(args.asm)
    if not path.is_file():
        print(f"错误：找不到文件 {path}", file=sys.stderr)
        return 2
    text = path.read_text(encoding="utf-8", errors="surrogateescape")

    if args.check:
        dups = find_duplicates(text)
        if dups:
            for name, owners in sorted(dups.items()):
                print(f"重名: {name} 出现于函数 {', '.join(map(str, owners))}")
            return 1
        print("无跨函数重名标签。")
        return 0

    new_text, renames, functions = rewrite(text)
    out_path = Path(args.out) if args.out else path
    out_path.write_text(new_text, encoding="utf-8", errors="surrogateescape")
    print(f"已处理 {path.name}: {functions} 个函数, 重命名 {renames} 处局部标签 -> {out_path.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
