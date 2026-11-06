#!/usr/bin/env python3
"""重复复杂算法压缩的尺寸对照（与 exp_shared.py 同口径）。

运行（在 tools/mcs2 下）：python exp_factor.py <标签>

编译器需先按目标状态重编：
  - 开启压缩：mcs2.zig 的 enable_factor = true  → python mcs2.py build
  - 关闭压缩（全部内联基线）：enable_factor = false → python mcs2.py build
两次运行的结果做差分，得到「同一算法每多一个调用点」的固件字节斜率。

口径：N 个同构 export fn（每个 a *% b），加同一个极简驱动，量 .ihx
的 0x00 数据记录字节总数（≈ CSEG）。

现行斜率 25 B/点（站点槽重绑定之后）。站点自身只多一条 lcall：输入靠
「块专用临时量」重绑直接写进拥有者槽，输出改成直接读拥有者槽。
"""
from __future__ import annotations

import sys

import mcs2
from exp_shared import ihx_bytes

FLAT_DRIVER = "    .area CSEG (CODE)\n    sjmp .\n"


def zig_source(n: int) -> str:
    return "".join(
        f"export fn m{i}(a: u16, b: u16) u16 {{ return a *% b; }}\n"
        for i in range(1, n + 1)
    )


def measure(tag: str, n: int) -> tuple[int, bool]:
    src = mcs2.BUILD / f"{tag}_{n}.zig"
    src.write_text(zig_source(n), encoding="utf-8")
    _, text = mcs2.emit_asm(src, f"{tag}_{n}")
    full = mcs2.merge(f"{tag}_{n}", FLAT_DRIVER, text)
    ihx = mcs2.assemble(full, f"{tag}_{n}", dseg=0x30)
    return ihx_bytes(ihx), "_mcs_sh_0" in text


def real_cases(tag: str) -> None:
    """真实负载口径：整份汇编单元的 CSEG 字节数。

    bench_compare.py 只量「单个函数体」，共享子程序是函数外的独立符号，
    不会被计入，所以开关对照在它那里看不出差别；这里用 .ihx 总字节补齐。
    """
    print(f"标签={tag}  真实用例 / CSEG字节 / 共享符号数")
    for src_name in ("div.zig", "mul.zig", "cordic_sin.zig"):
        src = mcs2.TESTS / src_name
        if not src.exists():
            continue
        case_tag = f"{tag}_real_{src.stem}"
        _, text = mcs2.emit_asm(src, case_tag)
        full = mcs2.merge(case_tag, FLAT_DRIVER, text)
        ihx = mcs2.assemble(full, case_tag, dseg=0x30)
        n = text.count("lcall _mcs_sh_")
        print(f"  {src_name:<20} {ihx_bytes(ihx):5d} B   {n}")


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == "real":
        real_cases(sys.argv[2] if len(sys.argv) > 2 else "factor")
        return
    tag = sys.argv[1] if len(sys.argv) > 1 else "factor"
    print(f"标签={tag}  N / CSEG字节 / 是否触发共享")
    sizes = []
    for n in (1, 2, 3, 4):
        size, shared = measure(tag, n)
        sizes.append(size)
        print(f"  {n}   {size:4d} B   {'是' if shared else '否'}")
    slopes = [sizes[i + 1] - sizes[i] for i in range(len(sizes) - 1)]
    print("  每多一个调用点：", slopes, "B")


if __name__ == "__main__":
    main()
