#!/usr/bin/env python3
"""尺寸对照实验：宏生成的共享 16 位乘法例程 vs mcs2 每处内联。

运行（在 tools/mcs2 下）：python exp_shared.py

口径：
  - 所有产物都加同一个极简驱动（sjmp .），量 .ihx 的数据字节（≈ CSEG）。
  - 组 A：N 个 export fn，每个 a *% b，mcs2 每处内联 3 次 MUL AB。
  - 组 B：N 个 export fn，每个 extern __mul16(a,b)，尾调用到共享库；
    共享库由 sdas8051 的 .macro 展开一次生成，遵守 mcs2 边界 ABI。
  - 用 N=1/2/4 的差分得到「每多一个调用点」的斜率与固定开销，算盈亏点。
  - 行为验证：N=1 换 driver_call 跑 ucsim，0x1234 *% 0x0020 应为 0x4680。
"""
from __future__ import annotations

import mcs2

BUILD = mcs2.BUILD

# sdas8051 的 .macro 参数替换是文本级，会误伤 a/b 等寄存器名；
# 这里用无参宏，只展开一次生成一份共享例程。
LIB_ASM = r"""
    .macro MUL16_LIB
    .area DSEG (DATA)
    .globl ___mul16_PARM_2
___mul16_PARM_2: .ds 1
    .globl ___mul16_PARM_3
___mul16_PARM_3: .ds 1
    .globl ___mul16_al
___mul16_al: .ds 1
    .globl ___mul16_hi
___mul16_hi: .ds 1
    .area CSEG (CODE)
    .globl ___mul16
___mul16:
    mov a,0x82
    mov ___mul16_al,a
    mov b,___mul16_PARM_2
    mul ab
    mov ___mul16_hi,b
    mov 0x82,a
    mov a,0x83
    mov b,___mul16_PARM_2
    mul ab
    add a,___mul16_hi
    mov ___mul16_hi,a
    mov a,___mul16_al
    mov b,___mul16_PARM_3
    mul ab
    add a,___mul16_hi
    mov 0x83,a
    ret
    .endm
    MUL16_LIB
"""

EXTERN_LINE = "extern fn __mul16(a: u16, b: u16) u16;\n"
FLAT_DRIVER = "    .area CSEG (CODE)\n    sjmp .\n"


def zig_source(n: int, shared: bool) -> str:
    lines = [EXTERN_LINE if shared else ""]
    for i in range(1, n + 1):
        expr = "__mul16(a, b)" if shared else "a *% b"
        lines.append(f"export fn m{i}(a: u16, b: u16) u16 {{ return {expr}; }}\n")
    return "".join(lines)


def build(tag: str, n: int, shared: bool, driver: str = FLAT_DRIVER):
    src = BUILD / f"{tag}.zig"
    src.write_text(zig_source(n, shared), encoding="utf-8")
    _, text = mcs2.emit_asm(src, tag)
    body = (LIB_ASM if shared else "") + "\n" + text
    full = mcs2.merge(tag, driver, body)
    ihx = mcs2.assemble(full, tag, dseg=0x30)
    return ihx, text


def ihx_bytes(path) -> int:
    """Intel HEX 里 0x00 数据记录的字节总数（不含 XSEG 的 .ds 占位）。"""
    total = 0
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.startswith(":"):
            continue
        rec = bytes.fromhex(line[1:])
        if rec[3] == 0x00:
            total += rec[0]
    return total


def main() -> None:
    results: dict[int, dict[bool, int]] = {}
    print("== 尺寸对照（CSEG 字节，含同一个极简驱动）")
    print(" N | 组A 内联 | 组B 共享 | A-B")
    for n in (1, 2, 4):
        vals: dict[bool, int] = {}
        for shared in (False, True):
            tag = f"exp_{'B' if shared else 'A'}_{n}"
            ihx, _ = build(tag, n, shared)
            vals[shared] = ihx_bytes(ihx)
        results[n] = vals
        print(f" {n} | {vals[False]:>8} | {vals[True]:>8} | {vals[False] - vals[True]:>+4}")

    a1, a4 = results[1][False], results[4][False]
    b1, b4 = results[1][True], results[4][True]
    slope_a = (a4 - a1) / 3
    slope_b = (b4 - b1) / 3
    fixed_a = a1 - slope_a
    fixed_b = b1 - slope_b
    print("\n== 每调用点增量 / 固定开销")
    print(f" 组A 内联：斜率 {slope_a:.1f} B/点，固定 {fixed_a:.1f} B")
    print(f" 组B 共享：斜率 {slope_b:.1f} B/点，固定 {fixed_b:.1f} B（含共享库本体）")
    print(f" 共享库本体约 {fixed_b - fixed_a:.1f} B（两组固定开销之差）")
    if slope_a > slope_b:
        cross = (fixed_b - fixed_a) / (slope_a - slope_b)
        print(f" 盈亏点：约 {cross:.2f} 个调用点，即 N ≥ {int(cross) + 1} 时共享例程更省 Flash")

    print("\n== 行为验证（组B，N=1）")
    driver = mcs2.driver_call(
        "m1",
        [("DPL", 0x34), ("DPH", 0x12), ("PARM2", 0x20), ("PARM_3", 0x00)],
        ret_bytes=2,
    )
    ihx, _ = build("exp_B_check", 1, True, driver=driver)
    got = mcs2.sim(ihx, steps=400, slots=2)
    lo, hi = got.get(0x8000), got.get(0x8001)
    ok = lo == 0x80 and hi == 0x46
    print(f" 0x1234 *% 0x0020 = 0x{hi:02X}{lo:02X}（期望 0x4680）→ {'PASS' if ok else 'FAIL'}")
    if not ok:
        raise SystemExit("行为验证失败")


if __name__ == "__main__":
    main()
