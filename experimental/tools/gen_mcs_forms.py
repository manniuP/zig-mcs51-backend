#!/usr/bin/env python3
"""为 Zig 后端生成 MCS-251 / MCS-51 指令形式表。

数据来源（唯一权威）：SDCC sdas251 测试门所用的规范 ISA 矩阵
    sdas/as251/tests/instruction-forms.tsv
以及指令族清单
    sdas/as251/tests/instruction-families.txt

输出：
    compiler/src/codegen/mcs/forms.zig

用法：
    python gen_mcs_forms.py [--tsv <path>] [--families <path>] [--out <path>]

TSV 各列依次为：
    id  mnemonic  operands  assembly  source_bytes  binary_bytes  flags  reference

其中 `source_bytes`/`binary_bytes` 是以空格分隔的十六进制字节串；`assembly` 是该形式
的一个具体、合法的汇编示例（寄存器编号与立即数仅为示例）；`{target}` 表示代码标签。
"""

import argparse
import os
import sys


HEADER = """//! 本文件由 tools/gen_mcs_forms.py 生成，请勿手工编辑。
//!
//! 规范的 MCS-251 / MCS-51 指令形式，转录自 SDCC sdas251 的 ISA 矩阵
//! （`sdas/as251/tests/instruction-forms.tsv`）。这是后端指令覆盖面的唯一权威：
//! 共 65 个指令族、269 种合法操作数形式，含 Source 模式与 Binary 模式的 opcode。
//!
//! `assembly` 字段是该形式的一个具体示例；`{target}` 表示控制流目标操作数。

/// 某个指令族的一种合法操作数形式。
pub const Form = struct {
    /// 稳定标识符，例如 `mov_a_imm8`。
    id: []const u8,
    /// 指令族，例如 `mov`。
    mnemonic: []const u8,
    /// 紧凑的操作数签名，例如 `A,#data`。
    operands: []const u8,
    /// 具体的 ASxxxx 汇编示例，例如 `mov a,#0x5a`。
    assembly: []const u8,
    /// MCS-251 Source 模式下的 opcode 字节。
    source_bytes: []const u8,
    /// MCS-251 Binary 模式下的 opcode 字节。
    binary_bytes: []const u8,
    /// 受影响的标志位，例如 `CY,AC,OV,N,Z` 或 `-`。
    flags: []const u8,
    /// 对应 Intel 指令表中的条目。
    reference: []const u8,
};

/// 65 个指令族（按 TSV 中的逻辑分组顺序）。
pub const families = [_][]const u8{
"""


def zstr(s):
    out = []
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


def zbytes(hexstr):
    parts = [p for p in hexstr.strip().split() if p]
    if not parts:
        return "&.{}"
    body = ", ".join("0x" + p.lower() for p in parts)
    return "&.{" + body + " }"


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    default_root = os.path.dirname(here)
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--tsv",
        default=os.path.join(
            default_root, "sdcc-c251", "sdas", "as251", "tests", "instruction-forms.tsv"
        ),
    )
    ap.add_argument(
        "--families",
        default=os.path.join(
            default_root, "sdcc-c251", "sdas", "as251", "tests", "instruction-families.txt"
        ),
    )
    ap.add_argument(
        "--out",
        default=os.path.join(default_root, "zig", "src", "codegen", "mcs", "forms.zig"),
    )
    args = ap.parse_args()

    with open(args.families, "r", encoding="utf-8") as f:
        families = [ln.strip() for ln in f if ln.strip()]

    rows = []
    with open(args.tsv, "r", encoding="utf-8") as f:
        lines = f.read().splitlines()
    header = lines[0].split("\t")
    if header[0] != "id":
        sys.exit("unexpected TSV header: %r" % header)
    for ln in lines[1:]:
        if not ln.strip():
            continue
        cols = ln.split("\t")
        if len(cols) != 8:
            sys.exit("expected 8 columns, got %d: %r" % (len(cols), ln))
        rows.append(cols)

    # 清单按字母排序，而 TSV 按逻辑分组。这里按 TSV 首次出现（逻辑）顺序输出，
    # 但要求两者集合一致。
    seen_families = []
    for r in rows:
        if r[1] not in seen_families:
            seen_families.append(r[1])
    if sorted(seen_families) != sorted(families):
        sys.exit(
            "family set in TSV does not match family manifest\n  only in tsv: %s\n  only in man: %s"
            % (
                sorted(set(seen_families) - set(families)),
                sorted(set(families) - set(seen_families)),
            )
        )
    families = seen_families

    out = [HEADER]
    for fam in families:
        out.append("    %s,\n" % zstr(fam))
    out.append("};\n\n")
    out.append("/// 全部 %d 种合法形式。\n" % len(rows))
    out.append("pub const forms = [_]Form{\n")
    for r in rows:
        out.append("    .{\n")
        out.append("        .id = %s,\n" % zstr(r[0]))
        out.append("        .mnemonic = %s,\n" % zstr(r[1]))
        out.append("        .operands = %s,\n" % zstr(r[2]))
        out.append("        .assembly = %s,\n" % zstr(r[3]))
        out.append("        .source_bytes = %s,\n" % zbytes(r[4]))
        out.append("        .binary_bytes = %s,\n" % zbytes(r[5]))
        out.append("        .flags = %s,\n" % zstr(r[6]))
        out.append("        .reference = %s,\n" % zstr(r[7]))
        out.append("    },\n")
    out.append("};\n")

    with open(args.out, "w", encoding="utf-8", newline="\n") as f:
        f.write("".join(out))

    print(
        "已写出 %s：%d 个指令族，%d 种形式"
        % (args.out, len(families), len(rows))
    )


if __name__ == "__main__":
    main()
