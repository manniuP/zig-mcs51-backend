#!/usr/bin/env python3
"""真机逐项验收：把 ucsim 那套算术用例搬到芯片上跑，UART 打印 + 主机比对。

在 zig-0.17/tools/mcs2 下：

    python realcheck.py --sim            # 构建全部组 + ucsim 自检（无板也能跑）
    python realcheck.py --build          # 只出固件（工作区 build/fw/real_*.ihx）
    python realcheck.py --read COM8      # 读串口逐项比对（需先烧录，pyserial）

设计要点：
  * 一组 = 一个测试源文件。mcs2 还没有 call，Zig 侧不能互相调用，
    所以外壳只能是汇编 + lcall 用例函数；整份 .asm 一起链（不裁剪函数），
    DSEG 需求 = 该文件全部函数的静态槽之和，实测都 ≤ 80 B。
  * mcs2 是「每函数一块静态 DSEG 槽」，所以不能把所有用例塞进一个固件 ——
    这也是 M2.14 活跃期分析要解决的真实约束。
  * 每条用例同时写 xdata（0x8000 + i*4）和 UART 打印：
    xdata 让 --sim 在 ucsim 里核对，UART 让真机核对 —— 同一份 .ihx。
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import mcs2

HERE = Path(__file__).resolve().parent
BUILD = mcs2.BUILD
FW_DIR = mcs2.WORKSPACE / "build" / "fw"

REAL_CASES = [
    "add", "mul8", "div8", "rem8", "not8", "xnor8", "shl2", "shr3", "setbit", "clrbit",
    "u16add", "u16sub", "u16carry", "u16shl", "u16shr", "u32add", "u32carry",
    "u16mul", "u16mul2", "i16mul", "u32mul",
    "u16div", "u16rem", "u32div", "u32rem", "i32div", "i32rem", "i8div", "i8rem", "i16div",
    "sexcmp", "sexcmp2", "sex16", "i32add", "sar32", "sar8",
    "ucmp_eq", "ucmp_gt", "ucmp_lt", "wbits", "shlv", "shrv", "shrv0", "sarv",
    "lt32", "lt32b", "ge8t", "ge8f",
]

def harness_head(board: str, fosc: float, baud: int) -> str:
    """crt0 + UART1 初始化。两种板子引脚/定时器不同，参数都必须与实机验证过的例程一致：

    * ai8051u（默认，本机唯一能下的板子）：UART1 → **P3.0/P3.1**，Timer2 1T 作波特率，
      配置照抄 zig_t0print（真机 115200 通过）；40 MHz 时 T2H:T2L = 0xFFA9。
    * stc8h：UART1 → P3.6/P3.7，Timer1 模式2（1T），照抄 uart_demo（45.1584 MHz @9600 → 0x6D）。
    """
    head = """\
    .area CSEG (CODE)
    ljmp _crt_main
_crt_main:
    mov sp,#0x7F
"""
    if board == "ai8051u":
        reload = 65536 - int((fosc / 4.0 + baud / 2.0) / baud)
        return head + f"""\
    ; UART1 -> P3.0(RxD)/P3.1(TxD)，Timer2 1T 作波特率（同 zig_t0print 的实机配置）
    mov 0xB1,#0x00          ; P3M1：P3.1 不设高阻
    mov 0xB2,#0x02          ; P3M0：P3.1 推挽输出（RxD 保持准双向）
    anl 0xA2,#0x3F          ; P_SW1.S1_S = 00 -> P3.0/P3.1
    mov 0x98,#0x50          ; SCON：模式1
    orl 0x8E,#0x01          ; AUXR.S1BRT：串口1 选 Timer2
    orl 0x8E,#0x04          ; AUXR.T2x12：Timer2 1T
    mov 0xD6,#0x{(reload >> 8) & 0xFF:02X}   ; T2H
    mov 0xD7,#0x{reload & 0xFF:02X}          ; T2L
    orl 0x8E,#0x10          ; AUXR.T2R：启动 Timer2
"""
    th1 = (256 - int(round(fosc / (32.0 * baud)))) & 0xFF
    return head + f"""\
    ; STC8H：UART1 -> P3.6(RxD)/P3.7(TxD)，Timer1 模式2（1T）
    mov 0xA2,#0x40
    mov 0xB1,#0x00
    mov 0xB2,#0x80
    mov 0x89,#0x20
    mov 0x8E,#0x40
    mov 0x8D,#0x{th1:02X}
    mov 0x8B,#0x{th1:02X}
    mov 0x88,#0x40
    mov 0x98,#0x40
"""

def harness_lib(wait_ti: bool) -> str:
    """打印子程序。wait_ti=True 给真机（等 TI 再发下一个字符）；
    False 给 ucsim（ucsim 的 SBUF/TI 时序不可靠，等它会卡死——只求把字符吐出来）。
    两种模式只有 _putw 不同，算术部分的 .ihx 完全一致。"""
    putw = ("_putw:\n"
            "_pw_loop:\n"
            "    jnb 0x99,_pw_loop\n"
            "    clr 0x99\n"
            "    ret\n") if wait_ti else "_putw:\n    ret\n"
    return """
    sjmp _fin
_phd:
    mov r6,a
    add a,#0x30
    mov r7,a
    mov a,r6
    clr c
    subb a,#0x0A
    mov a,r7
    jc _phd_out
    add a,#0x07
_phd_out:
    mov 0x99,a
    acall _putw
    ret
_ph8:
    mov b,a
    swap a
    anl a,#0x0F
    acall _phd
    mov a,b
    anl a,#0x0F
    acall _phd
    ret
_puts:
    mov 0x99,a
    acall _putw
    ret
""" + putw


def putc_asm(text: str) -> str:
    return "".join(f"    mov a,#{ord(ch)}\n    acall _puts\n" for ch in text)


def ret_bytes(spec: dict) -> int:
    if spec.get("want32") is not None:
        return 4
    if spec.get("want16") is not None:
        return 2
    return spec.get("ret_bytes", 1)


def case_asm(name: str, spec: dict, slot: int) -> str:
    """摆参（SDCC ABI）→ lcall → 写 xdata(slot) → 打印 name=HEX。低字节序。"""
    out = []
    for pos, val in spec["args"]:
        if pos in ("DPL", "DPH", "B", "ACC"):
            out.append(f"    mov {pos.lower()},#0x{val:02X}\n")
        elif pos == "PARM2":
            out.append(f"    mov _{spec['fn']}_PARM_2,#0x{val:02X}\n")
        elif pos.startswith("PARM_"):
            out.append(f"    mov _{spec['fn']}_{pos},#0x{val:02X}\n")
        else:
            raise SystemExit(f"未知参数位置 {pos}")
    out.append(f"    lcall _{spec['fn']}\n")
    rb = ret_bytes(spec)
    if rb == 1:
        out.append(f"    push dpl\n    mov dptr,#0x{slot:04X}\n    pop 0xE0\n    movx @dptr,a\n")
    else:
        regs = {2: ["dpl", "dph"], 4: ["dpl", "dph", "b", "acc"]}[rb]
        for reg in reversed(regs):
            out.append(f"    push {reg}\n")
        out.append(f"    mov dptr,#0x{slot:04X}\n")
        for _ in regs:
            out.append("    pop 0xE0\n    movx @dptr,a\n    inc dptr\n")
    out.append(putc_asm(f"{name}="))
    for k in range(rb):
        out.append(f"    mov dptr,#0x{slot + k:04X}\n    movx a,@dptr\n    acall _ph8\n")
    out.append(putc_asm("\r\n"))
    return "".join(out)


def build_group(cases: list[str], idx: int, board: str, fosc: float, baud: int,
                wait_ti: bool = True) -> tuple[Path, Path]:
    """一组（同一 src 文件）→ (ihx, 合并后的 asm)。"""
    src = mcs2.CASES[cases[0]]["src"]
    suffix = "" if wait_ti else "_sim"
    _, body = mcs2.emit_asm(HERE / "tests" / src, f"real_g{idx}{suffix}")
    harness = harness_head(board, fosc, baud)
    for i, c in enumerate(cases):
        harness += case_asm(c, mcs2.CASES[c], 0x8000 + i * 4)
    harness += harness_lib(wait_ti) + "_fin:\n    sjmp .\n"
    tag = f"real_g{idx}{suffix}_{src.split('.')[0]}"
    merged = mcs2.merge(tag, harness, body)
    ihx = mcs2.assemble(merged, tag, dseg=0x30, cseg=0x0000)
    return ihx, merged


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sim", action="store_true", help="构建并 ucsim 自检")
    ap.add_argument("--build", action="store_true", help="只出 .ihx 到 build/fw/")
    ap.add_argument("--read", metavar="PORT", help="读串口逐项比对（例 COM8）")
    ap.add_argument("--board", choices=("ai8051u", "stc8h"), default="ai8051u",
                    help="ai8051u：UART1 → P3.0/P3.1 + Timer2（默认）；stc8h：P3.6/P3.7 + Timer1")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--fosc", type=float, default=40000000.0)
    ap.add_argument("--cases", nargs="*", default=None)
    ap.add_argument("--group", type=int, default=None, help="只跑某一组（序号）")
    args = ap.parse_args()
    if not (args.sim or args.build or args.read):
        ap.print_help()
        return 2

    if args.board == "ai8051u":
        reload = 65536 - int((args.fosc / 4.0 + args.baud / 2.0) / args.baud)
        if not 1 <= reload <= 0xFFFF:
            raise SystemExit(f"Timer2 重载越界（{reload}）：检查 --fosc/--baud")
        baud_note = f"T2H:T2L=0x{reload:04X}"
    else:
        th1 = (256 - int(round(args.fosc / (32.0 * args.baud)))) & 0xFF
        if th1 == 0:
            raise SystemExit(f"TH1 越界：检查 --fosc/--baud（当前 {args.fosc:.0f}/{args.baud}）")
        baud_note = f"TH1=0x{th1:02X}"
    cases = args.cases or REAL_CASES

    by_src: dict[str, list[str]] = {}
    order: list[str] = []
    for c in cases:
        src = mcs2.CASES[c]["src"]
        if src not in by_src:
            by_src[src] = []
            order.append(src)
        by_src[src].append(c)

    print(f"== {len(cases)} 项 / {len(order)} 组（每组一个源文件），"
          f"{args.board} {args.fosc / 1e6:.3f} MHz @ {args.baud}（{baud_note}）")
    if args.group is not None:
        order = [order[args.group]]

    ok_all = True
    for gi, src in enumerate(order):
        g = by_src[src]
        ihx, merged = build_group(g, gi, args.board, args.fosc, args.baud, wait_ti=not args.sim)
        asm_text = merged.read_text(encoding="utf-8", errors="replace")
        nds = len(re.findall(r"^(_mcs_v\d+|_\w+_PARM_\d+): \.ds 1$", asm_text, re.M))
        print(f"  组{gi} {src}: {', '.join(g)}  ({nds} B DSEG)")
        if args.build or args.read:
            FW_DIR.mkdir(parents=True, exist_ok=True)
            dst = FW_DIR / f"real_g{gi}_{src.split('.')[0]}_{args.board}_{args.baud}.ihx"
            dst.write_bytes(ihx.read_bytes())
            print(f"    → {dst}")
        if args.sim:
            expect = []
            for i, c in enumerate(g):
                spec = mcs2.CASES[c]
                rb = ret_bytes(spec)
                w = spec.get("want32", spec.get("want16", spec.get("want")))
                for k in range(rb):
                    expect.append((0x8000 + i * 4 + k, (w >> (8 * k)) & 0xFF, c))
            steps = sum(mcs2.CASES[c].get("steps", 400) for c in g) + 800
            got = mcs2.sim(ihx, steps=steps, slots=1, extra=[(0x8000, len(g) * 4)])
            bad = [(c, a, got.get(a), w) for a, w, c in expect if got.get(a) != w]
            for c, a, have, want in bad:
                print(f"    FAIL {c} @0x{a:04X} = {have}（期望 {want}）")
                ok_all = False
            if not bad:
                print(f"    PASS 组{gi} {len(g)} 项")
    if args.read:
        return read_serial(args.read, args.baud, order, by_src)
    print("PASS: 仿真自检全部通过" if ok_all else "FAIL: 有组不一致")
    return 0 if ok_all else 1


def read_serial(port: str, baud: int, order: list[str], by_src: dict[str, list[str]]) -> int:
    try:
        import serial  # pyserial
    except ImportError:
        print("缺 pyserial：pip install pyserial")
        return 2
    want: dict[str, tuple[int, int]] = {}
    for src in order:
        for c in by_src[src]:
            spec = mcs2.CASES[c]
            want[c] = (spec.get("want32", spec.get("want16", spec.get("want"))), ret_bytes(spec))
    seen: dict[str, int] = {}
    print(f"== 读 {port} @{baud}：逐组烧录，打印 名字=HEX（共 {len(want)} 项）")
    with serial.Serial(port, baud, timeout=1) as sp:
        while len(seen) < len(want):
            line = sp.readline().decode("ascii", "replace").strip()
            m = re.match(r"^([a-z0-9_]+)=([0-9A-Fa-f]+)$", line)
            if not m or m.group(1) not in want:
                continue
            name, hexv = m.group(1), m.group(2)
            raw = bytes.fromhex(hexv)
            val = sum(b << (8 * k) for k, b in enumerate(raw))
            seen[name] = val
            w, rb = want[name]
            good = val == w
            print(f"  {'PASS' if good else 'FAIL'} {name} = 0x{val:0{rb * 2}X}（期望 0x{w:0{rb * 2}X}）")
    missing = [c for c in want if c not in seen]
    if missing:
        print(f"FAIL: 缺 {', '.join(missing)}")
        return 1
    print("PASS: 真机逐项一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
