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
import os
import re
import sys
from pathlib import Path

import mcs2

# AiCube 的自动下载只监视它**界面底部路径框里那个文件**，不是固定文件名。
# 这里只读地问出来，省掉每次手工 --live（2026-11-06 因为默认路径对不上，
# 写入后静默不烧，看起来像固件有问题，白查一轮）。非 Windows 或没装就跳过。
try:
    import aicube
except Exception:  # noqa: BLE001 - 非 Windows 平台没有 user32
    aicube = None

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
    # 运行期下标 + 多字节元素（scale=1/2/4；单元素与相邻两元素）
    "t8rt", "t8pair", "t16rt", "t16pair", "t32rt", "t32pair",
    # 全局数组的符号基址（mov dptr,#_sym）：常量下标 / 运行期下标 / u8 / 相邻两元素
    "symconst", "symrt", "symb", "sympair",
    # 函数指针表：@intFromPtr 填表 + table[i] + @ptrFromInt 间接调用
    "fpt_all",
    # const 表（代码段 .db + movc 读）：常量下标 / 运行期下标 / u16 元素
    "cget2", "cgeti", "wgeti",
    # 真 switch / if·switch 表达式 / 宽局部量 / 16-32 位运行期移位
    "sw1h", "sw1m", "sw2r", "sw2h", "sw2e", "sw3a", "sw3b",
    "ifx1", "ifx0", "ifr1", "ifr0", "swx2", "swx9", "ifw1", "ifw0",
    "wloc1", "wloc2", "s16r", "u16l", "u32l",
    # CORDIC 定点数学库（lib/cordic.zig）
    "csin90", "csin45", "csin180", "ccos0", "cat90", "cat45",
    # ---- 2026-11-01 新增能力（仿真已过，真机补测）----
    # 尾递归：自递归编成循环 + 互递归（ljmp 到另一函数），栈不增长
    "trsum", "trev", "trod",
    # 运行期指针做基址：p[i] 写后读 / u16 元素（scale=2）/ 二维 p[i][j]
    "pprt", "pu16", "p2d",
    # 三维数组（帧缓冲）：固定地址 3D / 全局 3D / 多维 vs 平面地址交叉验证
    "fb3d", "gfb", "fbchk",
    # 多字节全局变量：写读 / 读改写 / 参与宽比较
    "wg32", "wg16", "wginc", "wgcmp1", "wgcmp0",
    # B 寄存器保护（arg0 是 32 位时，表下标的 MUL 不能踩掉 arg2）
    "bscale",
    # ---- 补齐历史遗留：这些一直是「只在仿真跑」的 ----
    # 局部量地址 / 循环 / 大循环 / 环形缓冲
    "varfn", "addrfn", "sum", "cnt", "sum_to_fold", "big", "ringdemo",
    # 内存/位操作边角（读改写、比较零）。
    # ⚠️ bitpoll/bitclear **不进真机**：bitpoll 会轮询一个外部状态位，
    # 硅片上那位不变就永远卡在循环里 —— 而 ISP 触发代码在打印循环之后，
    # 固件挂住就再也接不到 @STCISP#，整轮自动烧录会被它锁死（踩过）。
    "memrt", "bitfn", "xor2", "ne5", "ne_imm",
    # 内部调用链 / 间接调用（函数指针）/ 参数搬运 / 命令分派
    "chain", "chain32", "mix32", "call_ind", "twice_ind", "call_addr",
    "argcall1", "argcall2", "argcall3", "dispatch",
    # 32 位 xdata 读写与四舍五入（wstore 只看内存、没有返回值 → 留在仿真里）
    "wround", "wround2", "addone",
    # 中断（ISR）：Timer0 中断里给 xdata 0x8000 计数，主循环反复打印 interrupt=NN。
    # 验收口径 = 「进得来中断 + ISR 跑完 + reti 回到主程序 + 计数在涨」，所以只要 NN ≥ 1。
    # 真机外壳：VECTORS 里放复位跳转（0x0000）+ ISR 向量（0x000B），CSEG 起点 0x0080。
    "interrupt",
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

# 收到任何一个串口字节 → 软复位进 ISP（STC 的 bootloader），免掉每组都要断电/按 RST。
# AI8051U 的 IAP_CONTR = 0xC7（官方 AI8051U.h 第 82 行），SWBS=bit6、SWRST=bit5 → 写 0x60。
# 用「任何字节」而不是魔法字：AiCube 的下载握手最早发出的是 0x7F，
# 但它按自己的下载波特率发（可能 2400），在 115200 下收到的是乱码——只认同一个值会漏。
# 中断版（主循环挂死时也能自救）：UART1 接收中断 → ISR 里同样写 IAP_CONTR=0x60。
# 向量 = 0x0003 + 8*4 = 0x0023（AI8051U 8 位模式，同 ziguart 的实机配置）。
# 为什么需要它：轮询版只在打印循环里检查，一旦某个用例自己卡在死循环（例如轮询外部状态位），
# 就再也接不到 @STCISP# → 整轮自动烧录被锁死（2026-11-01 踩过）。中断版不受主循环影响。
ISP_VECTOR = """
    .area VECTORS (ABS,CODE)
    .org 0x0023
    ljmp _isp_isr
    .area CSEG (CODE)
_isp_isr:
    jnb 0x98,_isp_ti        ; RI=0 → 这是 TI（发送完成）中断，不是下载命令
    mov a,0x99              ; 读 SBUF（硬件清 RI）
    mov 0xA8,#0x00          ; IE=0：不再接受新中断（马上要复位）
    mov 0xC7,#0x60          ; IAP_CONTR：SWBS=1 + SWRST=1 → 进 ISP
    reti                    ; （复位在即，走不到这里）
_isp_ti:
    clr 0x99                ; 清 TI：打印子程序靠它判断发送完成
    reti
"""

ISP_WATCH = """
    ; ---- 串口收到字节就软复位进 ISP（下载模式），不需要按 RST/断电 ----
    ; 注意 jb/jnb 只有 ±127 的射程，_again 在整块用例之前（几百字节外）→ 落到 ljmp。
    jb 0x98,_isp_hit       ; SCON.RI（位地址 0x98）= 1 → 收到字节
    ljmp _again            ; 没收到 → 继续循环打印
_isp_hit:
    mov a,0x99             ; 读 SBUF，硬件自动清 RI
    mov 0xC7,#0x60         ; IAP_CONTR：SWBS=1 从 ISP 区启动 + SWRST=1 软复位
    sjmp .                 ; 等芯片复位（复位后由 ISP 等下载）
"""


def harness_lib(wait_ti: bool) -> str:
    """打印子程序。wait_ti=True 给真机（等 TI 再发下一个字符）；
    False 给 ucsim（ucsim 的 SBUF/TI 时序不可靠，等它会卡死——只求把字符吐出来）。
    两种模式只有 _putw 不同，算术部分的 .ihx 完全一致。"""
    # 真机版：等 TI，但**有上限**（r4/r5 两级计数器，~2.5 ms/字符）——
    # 万一 UART 没配对，宁可丢字符也不能把固件挂死在这里。
    putw = ("_putw:\n"
            "    mov r5,#0xC8\n"
            "_pw_outer:\n"
            "    mov r4,#0x00\n"
            "_pw_loop:\n"
            "    jb 0x99,_pw_done\n"
            "    djnz r4,_pw_loop\n"
            "    djnz r5,_pw_outer\n"
            "_pw_done:\n"
            "    clr 0x99\n"
            "    ret\n") if wait_ti else "_putw:\n    ret\n"
    return """
    ljmp _again
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
        elif pos == "SYM16":
            # 传一个符号的 16 位地址（拆低/高字节）—— 间接调用/函数指针测试用
            out.append(f"    mov dpl,#<{val}\n    mov dph,#>{val}\n")
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


def isr_asm(isp: bool) -> str:
    """ISR 组的外壳：起 Timer0 中断，主循环反复打印 xdata 0x8000 的计数值。

    T2 已被波特率占用，所以计数器用 Timer0（与 interrupt.zig 的 ISR 一致：
    向量号 1 → 0x000B，mcs2 自动发向量跳板）。
    验收口径：只要打印出 `isr=XX` 且 XX ≥ 1，就说明「真机中断进得来、ISR 跑完、
    reti 回主程序、xdata 计数在涨」这条链路成立。
    """
    out = """    mov 0x89,#0x01        ; TMOD：T0 = 模式1（16 位）
    mov 0x8C,#0xF0        ; TH0
    mov 0x8A,#0x00        ; TL0
    mov 0xA8,#0x82        ; IE：EA=1, ET0=1
    setb 0x8C             ; TCON.TR0 = 1（位地址 0x8C = TCON.4）
_again:
""" + putc_asm("interrupt=") + """    mov dptr,#0x8000
    movx a,@dptr
    acall _ph8
""" + putc_asm("\r\n")
    if isp:
        out += ISP_WATCH
    return out


def build_group(cases: list[str], idx: int, board: str, fosc: float, baud: int,
                wait_ti: bool = True, isp: bool = False) -> tuple[Path, Path]:
    """一组（同一 src 文件）→ (ihx, 合并后的 asm)。"""
    src = mcs2.CASES[cases[0]]["src"]
    suffix = "" if wait_ti else "_sim"
    _, body = mcs2.emit_asm(mcs2.TESTS / src, f"real_g{idx}{suffix}")
    harness = harness_head(board, fosc, baud)
    if mcs2.CASES[cases[0]].get("kind") == "interrupt":
        # 中断组：没有「调用-取返回值」的形状，单独拼外壳
        # 复位跳转必须放进**绝对向量区**（0x0000），CSEG 让到 0x0080 之后：
        # 否则「复位向量」和「中断向量」只能二选一（前者在 CSEG 头，后者在 VECTORS）。
        harness = harness.replace(
            "    .area CSEG (CODE)\n    ljmp _crt_main\n",
            "    .area VECTORS (ABS,CODE)\n    .org 0x0000\n    ljmp _crt_main\n    .area CSEG (CODE)\n",
            1,
        )
        harness += isr_asm(isp)
        harness += harness_lib(wait_ti)
        tag = f"real_g{idx}{suffix}_{src.split('.')[0]}"
        merged = mcs2.merge(tag, harness, body)
        # 中断组必须把 CSEG 让开向量区（0x0003 + 8*13 = 0x006B），否则代码压掉向量表 →
        # 芯片一中断就跳进垃圾（表现为「烧完一声不响」）。
        ihx = mcs2.assemble(merged, tag, dseg=0x30, cseg=0x0080)
        return ihx, merged
    # 整组结果**反复打印**：烧完随时接串口都能收到（接线/烧录占着串口的顺序不再冲突）。
    harness += "_again:\n"
    for i, c in enumerate(cases):
        harness += case_asm(c, mcs2.CASES[c], 0x8000 + i * 4)
    if isp:
        # 只用轮询版：UART 中断与 _putw 的 TI 轮询会打架（ISR 清掉 TI，主机永远等不到），
        # 实测开了中断反而一个字都打不出来。挂死类用例改成「不进真机套件」来规避。
        harness += ISP_WATCH
    harness += harness_lib(wait_ti)
    tag = f"real_g{idx}{suffix}_{src.split('.')[0]}"
    merged = mcs2.merge(tag, harness, body)
    ihx = mcs2.assemble(merged, tag, dseg=0x30, cseg=0x0000)
    return ihx, merged


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sim", action="store_true", help="构建并 ucsim 自检")
    ap.add_argument("--build", action="store_true", help="只出 .ihx 到 build/fw/")
    ap.add_argument("--read", metavar="PORT", help="读串口逐项比对（例 COM8）")
    ap.add_argument("--dl", metavar="PORT",
                    help="只发一次触发字节让固件软复位进 ISP（AiCube 点下载前/后都行）")
    ap.add_argument("--auto", metavar="PORT",
                    help="全自动：逐组写 AiCube 监视的 .ihx（文件一变它自己烧）+ 轮询收数")
    ap.add_argument("--live", default=None,
                    help="--auto 用的「被监视」文件路径。不给就自动从 AiCube 窗口读"
                         "（读不到才退回 build/fw/real_live_*.ihx）")
    ap.add_argument("--per-group", type=float, default=8.0,
                    help="--auto 每次读窗口（秒）")
    ap.add_argument("--flash-wait", type=float, default=14.0,
                    help="--auto 写文件后**关着串口**等 AiCube 烧完的秒数（这段时间别碰串口！）")
    ap.add_argument("--tries", type=int, default=3, help="--auto 每组最多重试次数")
    ap.add_argument("--watch", metavar="PORT",
                    help="边烧边收：轮询串口累积各组结果，直到 48 项收齐或超时")
    ap.add_argument("--open", type=float, default=0.6, help="--watch 每次开串口读多久")
    ap.add_argument("--close", type=float, default=5.4, help="--watch 两次读之间关多久（让 AiCube 下载）")
    ap.add_argument("--seconds", type=float, default=20.0,
                    help="--watch/--read 最长秒数（--read 收齐即退）")
    ap.add_argument("--isp", action="store_true",
                    help="固件里加「收到串口字节就软复位进 ISP」（pc: jb SCON.RI → SBUF → IAP_CONTR=0x60）。"
                         "注意：它只能让**已经在跑本版固件**的芯片进 ISP；芯片里若是旧固件（没有这段），"
                         "第一次仍要人工复位/断电一次，之后就能全自动")
    ap.add_argument("--board", choices=("ai8051u", "stc8h"), default="ai8051u",
                    help="ai8051u：UART1 → P3.0/P3.1 + Timer2（默认）；stc8h：P3.6/P3.7 + Timer1")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--fosc", type=float, default=40000000.0)
    ap.add_argument("--cases", nargs="*", default=None)
    ap.add_argument("--group", type=int, default=None, help="只跑某一组（序号）")
    args = ap.parse_args()
    if args.dl:
        return send_download(args.dl, args.baud)
    if args.watch:
        return watch(args.watch, args.baud, args.seconds, args.open, args.close)
    if args.auto:
        if args.live is None:
            got = aicube.loaded_ihx() if aicube else None
            args.live = got or str(FW_DIR / "real_live_ai8051u_115200.ihx")
            if got:
                print(f"--live 未指定：用 AiCube 当前装载的 {args.live}")
            else:
                print(f"--live 未指定，且读不到 AiCube 路径，退回 {args.live}")
                print("（若 AiCube 监视的是别的文件，写它不会触发下载）")
        by_src2: dict[str, list[str]] = {}
        order2: list[str] = []
        for c in (args.cases or REAL_CASES):
            s = mcs2.CASES[c]["src"]
            if s not in by_src2:
                by_src2[s] = []
                order2.append(s)
            by_src2[s].append(c)
        return auto(Path(args.live), args.auto, args.baud, order2, by_src2,
                    args.per_group, args.flash_wait, args.tries)
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
        ihx, merged = build_group(g, gi, args.board, args.fosc, args.baud,
                                  wait_ti=not args.sim, isp=args.isp)
        asm_text = merged.read_text(encoding="utf-8", errors="replace")
        nds = len(re.findall(r"^(_mcs_v\d+|_\w+_PARM_\d+): \.ds 1$", asm_text, re.M))
        print(f"  组{gi} {src}: {', '.join(g)}  ({nds} B DSEG)")
        if args.build or args.read:
            FW_DIR.mkdir(parents=True, exist_ok=True)
            dst = FW_DIR / f"real_g{gi}_{src.split('.')[0]}_{args.board}_{args.baud}.ihx"
            dst.write_bytes(ihx.read_bytes())
            print(f"    → {dst}")
        if args.sim and mcs2.CASES[g[0]].get("kind") == "interrupt":
            # 中断组没有「返回值」可比：查形状（ISR 存/取现场成对、有 reti、向量在 0x000B）
            pushes = asm_text.count("\n    push ")
            pops = asm_text.count("\n    pop ")
            reti = "\n    reti" in asm_text
            vec = "0x000B" in asm_text.upper().replace("0X", "0x")
            shape_ok = pushes > 0 and pushes == pops and reti and vec
            print(f"    {'PASS' if shape_ok else 'FAIL'} ISR 形状：push {pushes} / pop {pops} / reti={reti} / 向量 0x000B={vec}")
            ok_all = ok_all and shape_ok
            continue
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
        return read_serial(args.read, args.baud, order, by_src, args.seconds)
    print("PASS: 仿真自检全部通过" if ok_all else "FAIL: 有组不一致")
    return 0 if ok_all else 1


def watch(port: str, baud: int, seconds: float, open_s: float = 0.6,
          close_s: float = 5.4) -> int:
    """边烧边收：短暂开门（1.2 s）+ 关门的轮询读法。

    为什么不是一直开着：AiCube 下载要**独占**串口，一直占着它就下不了；
    而固件是循环重复打印的，所以「开 1.2 s 关 2 s」也能把每组的结果都收齐。
    """
    try:
        import serial
    except ImportError:
        print("缺 pyserial：pip install pyserial")
        return 2
    import time

    want: dict[str, tuple[int, int]] = {}
    for c in REAL_CASES:
        spec = mcs2.CASES[c]
        want[c] = (spec.get("want32", spec.get("want16", spec.get("want"))), ret_bytes(spec))
    seen: dict[str, int] = {}
    buf = b""
    deadline = time.time() + seconds
    seconds = min(seconds, 300.0)   # 别留长命后台：被强杀时子进程会成孤儿（踩过）
    print(f"== 轮询 {port}@{baud}，最长 {seconds:.0f} s（PID {os.getpid()}，强杀请按 PID）")
    while len(seen) < len(want) and time.time() < deadline:
        try:
            with serial.Serial(port, baud, timeout=0.2) as sp:
                sp.reset_input_buffer()
                t_end = time.time() + open_s
                while time.time() < t_end and len(seen) < len(want):
                    chunk = sp.read(256)
                    if not chunk:
                        continue
                    buf += chunk
                    while b"\r\n" in buf:
                        line, buf = buf.split(b"\r\n", 1)
                        m = re.match(rb"^([a-z0-9_]+)=([0-9A-Fa-f]+)$", line.strip())
                        if not m:
                            continue
                        name = m.group(1).decode()
                        if name in seen or name not in want:
                            continue
                        raw = bytes.fromhex(m.group(2).decode())
                        val = sum(b << (8 * k) for k, b in enumerate(raw))
                        seen[name] = val
                        w, rb = want[name]
                        ok = val == w
                        print(f"  {'PASS' if ok else 'FAIL'} {name} = 0x{val:0{rb * 2}X}"
                              f"（期望 0x{w:0{rb * 2}X}）  [{len(seen)}/{len(want)}]")
            time.sleep(2.0)
        except Exception:
            time.sleep(0.8)   # 端口被 AiCube 占着，等它下完
        time.sleep(close_s)
    missing = [c for c in want if c not in seen]
    if missing:
        print(f"还缺 {len(missing)} 项：{', '.join(missing)}")
        return 1
    print(f"PASS: 真机 {len(want)} 项全部一致")
    return 0


def _collect(port: str, baud: int, results: dict[str, int], want: set[str],
             seconds: float, open_s: float = 0.6, close_s: float = 5.4) -> None:
    """开短窗轮询收集：开 1.2 s / 关 2 s（AiCube 下载要独占串口）。"""
    import serial
    import time

    deadline = time.time() + seconds
    buf = b""
    while time.time() < deadline and not want.issubset(results):
        try:
            with serial.Serial(port, baud, timeout=0.2) as sp:
                sp.reset_input_buffer()
                t_end = min(time.time() + open_s, deadline)
                while time.time() < t_end and not want.issubset(results):
                    chunk = sp.read(256)
                    if not chunk:
                        continue
                    buf += chunk
                    while b"\r\n" in buf:
                        line, buf = buf.split(b"\r\n", 1)
                        m = re.match(rb"^([a-z0-9_]+)=([0-9A-Fa-f]+)$", line.strip())
                        if not m:
                            continue
                        name = m.group(1).decode()
                        if name in results or name not in mcs2.CASES:
                            continue
                        raw = bytes.fromhex(m.group(2).decode())
                        results[name] = sum(b << (8 * k) for k, b in enumerate(raw))
                        w = _want(name)
                        rb = _want_bytes(name)
                        # 中断组没有固定期望值（计数随中断次数变）：≥1 即证明中断链路成立
                        if mcs2.CASES[name].get("kind") == "interrupt":
                            w = results[name] if results[name] >= 1 else 0
                            good = results[name] >= 1
                        else:
                            good = results[name] == w
                        print(f"  {'PASS' if good else 'FAIL'} {name} = "
                              f"0x{results[name]:0{rb * 2}X}（期望 0x{w:0{rb * 2}X}）")
        except Exception:
            time.sleep(0.8)
        time.sleep(close_s)


def auto(live: Path, port: str, baud: int, order: list[str],
         by_src: dict[str, list[str]], per_group: float = 30.0,
         flash_wait: float = 14.0, tries: int = 3) -> int:
    """真的全自动：把每组的 .ihx 写到 AiCube 监视的那个路径上，
    AiCube 一看到文件变化就烧，固件跑起来我们轮询收数——不用点任何按钮。"""
    import time

    FW_DIR.mkdir(parents=True, exist_ok=True)
    live.parent.mkdir(parents=True, exist_ok=True)
    print(f"PID {os.getpid()}（后台跑时强杀请按 PID，只杀 pwsh 会留下孤儿抢串口）")
    results: dict[str, int] = {}
    # 先听 3 s 看芯片上现在跑的是哪一组：已收齐的组直接跳过，重跑本命令不浪费烧录次数。
    every: set[str] = set()
    for s in order:
        every.update(by_src[s])
    print("== 先听 3 s 看当前跑的是哪组…")
    _collect(port, baud, results, every, 3.0)
    if results:
        print(f"   已收到 {len(results)} 项：{', '.join(sorted(results))}")
    for gi, src in enumerate(order):
        cases = by_src[src]
        if all(c in results for c in cases):
            print(f"[组{gi}] 已在芯片上跑过，跳过")
            continue
        # 按「源文件名」找固件，不按组号：用例表增删后组号会平移，组号写死会让
        # 「只补跑几组」（--cases）找不到文件。
        #
        # 同一源文件会留下多份历史固件（组号平移后旧的不删），**必须按 mtime 取最新**。
        # 按文件名排序看着也行，但 "real_g9_" 排在 "real_g12_" 后面（字符串比较），
        # 会挑到旧的那份——旧的可能不带 --isp 那段，烧上去之后芯片就不能再自动
        # 进 ISP，后续每组都要断电，症状是「热起来好好的，跑一半全失败」。
        stem = src.split(".")[0]
        cands = sorted(FW_DIR.glob(f"real_g*_{stem}_ai8051u_{baud}.ihx"),
                       key=lambda p: p.stat().st_mtime)
        if not cands:
            print(f"缺固件 real_g*_{stem}_ai8051u_{baud}.ihx：先跑 python realcheck.py --build --baud {baud}")
            return 2
        src_ihx = cands[-1]
        payload = src_ihx.read_bytes()
        print(f"[组{gi}/{len(order) - 1}] 写 {live.name} ← {src_ihx.name}"
              f"（{len(cases)} 项：{', '.join(cases)}）")
        for attempt in range(tries):
            live.write_bytes(payload)          # 每次重写都会更新 mtime → 触发「文件变化就下载」
            # 关键：烧录窗口内**完全不碰串口**，让 AiCube 独占。
            time.sleep(flash_wait)
            _collect(port, baud, results, set(cases), per_group)
            if all(c in results for c in cases):
                break
            if attempt + 1 < tries:
                miss = [c for c in cases if c not in results]
                print(f"  组{gi} 第 {attempt + 1} 次没收全（缺 {', '.join(miss)}），重试…")
        if not all(c in results for c in cases):
            miss = [c for c in cases if c not in results]
            print(f"  组{gi} 放弃（缺 {', '.join(miss)}）——检查 AiCube 的自动下载开关")
    all_cases = [c for src in order for c in by_src[src]]
    missing = [c for c in all_cases if c not in results]
    print(f"== 收齐 {len(results)}/{len(all_cases)}")
    if missing:
        print(f"FAIL: 缺 {', '.join(missing)}")
        return 1
    print("PASS: 真机逐项全部一致")
    return 0


def _want(name: str) -> int:
    spec = mcs2.CASES[name]
    return spec.get("want32", spec.get("want16", spec.get("want")))


def _want_bytes(name: str) -> int:
    return ret_bytes(mcs2.CASES[name])


def send_download(port: str, baud: int) -> int:
    """给正在跑的固件发字节 → 它写 IAP_CONTR=0x60 软复位进 ISP。"""
    try:
        import serial
    except ImportError:
        print("缺 pyserial：pip install pyserial")
        return 2
    payload = bytes([0x7F, 0x7F, 0x7F, 0xA5, 0x7F])
    with serial.Serial(port, baud, timeout=0.3) as sp:
        sp.write(payload)
        sp.flush()
    print(f"已向 {port}@{baud} 发 {payload.hex(' ')}：固件应已软复位进 ISP（等着 AiCube 下载）")
    return 0


def read_serial(port: str, baud: int, order: list[str], by_src: dict[str, list[str]],
                seconds: float = 20.0) -> int:
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
    import time

    seen: dict[str, int] = {}
    deadline = time.time() + seconds
    print(f"== 读 {port} @{baud}，最长 {seconds:.0f} s（共 {len(want)} 项待收）")
    with serial.Serial(port, baud, timeout=1) as sp:
        while len(seen) < len(want) and time.time() < deadline:
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
