#!/usr/bin/env python3
"""ASM -> MCS51 .rel -> .ihx。

这是 mcs2 的 51 构建后端，不依赖 Zig 编译器：
  - 输入：sdas8051 可接受的 ASxxxx 汇编；
  - 输出：Intel HEX（.ihx）——STC 下载器直接接受，无需 packihx 再转换。

固定布局（最小切片）：
  CSEG = 0x0000，DSEG = 0x08。
正式后端必须从设备的链接布局读取，不得把这两个值写死。
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
WORKSPACE = HERE.parents[2]


def toolchain_dir() -> Path:
    return Path(os.environ.get(
        "MCS_SDCC_BIN",
        WORKSPACE / "mcs251" / "tools" / "sdcc-mcs251-windows-x64" / "sdcc-mcs251" / "bin",
    ))


def run(cmd: list[str]) -> None:
    print("+", " ".join(str(c) for c in cmd))
    subprocess.run(cmd, check=True, capture_output=True, text=True)


def assemble(asm: Path, out_dir: Path, name: str = "out", dseg_base: int = 0x08,
             cseg_base: int = 0x0000) -> Path:
    """把一份 51 汇编变成 .ihx，返回其路径。cseg_base 供向量表布局使用
    （中断向量在 0x0000-0x002F 时，CSEG 挪到 0x30 之后）。"""
    bindir = toolchain_dir()
    sdas = bindir / "sdas8051.exe"
    sdld = bindir / "sdld.exe"
    for tool in (sdas, sdld):
        if not tool.exists():
            raise FileNotFoundError(f"找不到工具：{tool}（设置 MCS_SDCC_BIN）")

    out_dir.mkdir(parents=True, exist_ok=True)
    rel = out_dir / f"{name}.rel"
    ihx = out_dir / f"{name}.ihx"
    lk = out_dir / f"{name}.lk"

    run([str(sdas), "-plosgffw", str(rel), str(asm)])

    lk.write_text(
        "\n".join([
            f"-i {ihx}",
            f"-b CSEG = 0x{cseg_base:04X}",
            f"-b DSEG = 0x{dseg_base:04X}",
            str(rel),
            "-e",
            "",
        ]),
        encoding="ascii",
        newline="\n",
    )
    run([str(sdld), "-f", str(lk)])

    return ihx


def main() -> int:
    parser = argparse.ArgumentParser(description="MCS51 ASM -> ihx")
    parser.add_argument("asm", type=Path)
    parser.add_argument("--out-dir", type=Path, default=HERE / "build")
    parser.add_argument("--name", default="out")
    parser.add_argument("--dseg-base", type=lambda s: int(s, 0), default=0x08)
    args = parser.parse_args()

    if not args.asm.exists():
        print(f"找不到汇编：{args.asm}", file=sys.stderr)
        return 2
    try:
        ihx = assemble(args.asm, args.out_dir, args.name, args.dseg_base)
    except (OSError, subprocess.CalledProcessError) as e:
        print(f"FAIL: {e}", file=sys.stderr)
        return 1

    print(f"OK: {ihx}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
