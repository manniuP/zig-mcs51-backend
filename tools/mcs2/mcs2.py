#!/usr/bin/env python3
"""mcs2 唯一入口：构建编译器 / 跑仿真验收 / 出实机固件。

     python mcs2.py sync             # 把 zig-0.17 的 mcs2 源码硬链接进构建树（幂等）
     python mcs2.py build            # 构建编译器（增量；产物 zig017/mcs2build/zig-out/bin/zig.exe）
     python mcs2.py check            # 跑全部仿真验收
     python mcs2.py check add loop   # 只跑点名的用例
     python mcs2.py fw uart          # 出实机固件（build/fw/*.ihx）
     python mcs2.py all              # sync + build + check

两棵树的分工（以前每改一次源码要手工 Copy-Item，现在由 sync 维护硬链接）：
  - zig-0.17/src/codegen/mcs2*     ← 我们编辑的源码（唯一真源）
  - zig017/mcs2build               ← 编译器构建树：src/lib 是打过 mcs51/mcs251 补丁的版本
  - 硬链接让两处是同一个文件，改 zig-0.17 立即对构建树生效；跨卷失败时自动退回复制。

布局约定（全局唯一一处）：
  DSEG=0x30（避开复位栈 0x08-0x09）、CSEG=0x0000；中断用例向量表占 0x0000-0x002F，CSEG 挪到 0x30。
  验收一律以 ucsim 的 xram 读回为准，不依赖串口时序；汇编/链接退出码必须检查。

依赖：系统 zig（构建编译器）、sdas8051/sdld（MCS_SDCC_BIN 可覆盖）、ucsim_51（UCSIM51 可覆盖）。
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent            # zig-0.17/tools/mcs2
SRC_TREE = HERE.parents[1]                         # zig-0.17：源码真源
WORKSPACE = HERE.parents[2]
BUILD_TREE = WORKSPACE / "zig017" / "mcs2build"    # 编译器构建树（带补丁的 src/lib）
CACHE = WORKSPACE / "zig017"                       # 缓存集中在这里，不污染源码树
GLOBAL_CACHE = CACHE / "cache-mcs2"
LOCAL_CACHE = CACHE / "cache-mcs2-local"
BUILD = HERE / "build"
ZIG_EXE = BUILD_TREE / "zig-out" / "bin" / "zig.exe"
TARGET = "mcs51-freestanding"

if os.environ.get("ZIG017"):                       # 兼容旧习惯：显式指定编译器
    ZIG_EXE = Path(os.environ["ZIG017"])

# 需要保持两处一致的文件（相对源码树）
SYNC_FILES = ["src/codegen/mcs2.zig"]
SYNC_GLOB = "src/codegen/mcs2/*.zig"


# ---------------------------------------------------------------- 源码同步

def sync(verbose: bool = True) -> int:
    """把 SRC_TREE 的 mcs2 源码硬链接进 BUILD_TREE（已是链接则跳过）。返回链接/复制数。"""
    if not BUILD_TREE.exists():
        raise SystemExit(
            f"构建树不存在：{BUILD_TREE}\n"
            "这是编译器构建树（src/lib 带 mcs51/mcs251 补丁）；恢复后才谈得上构建。")
    rels = list(SYNC_FILES)
    rels += [str(p.relative_to(SRC_TREE)) for p in sorted(SRC_TREE.glob(SYNC_GLOB))]
    changed = 0
    for rel in rels:
        src = SRC_TREE / rel
        dst = BUILD_TREE / rel
        if not src.exists():
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        if dst.exists():
            try:
                if os.path.samefile(src, dst):      # 已是同一个文件（硬链接）
                    continue
            except OSError:
                pass
            # 内容相同且非链接 → 也补成链接（一次性把旧拷贝升级）
            try:
                same = src.read_bytes() == dst.read_bytes()
            except OSError:
                same = False
            if not same:
                print(f"  注意：{rel} 两处内容不同，以 {SRC_TREE.name} 为准")
            dst.unlink()
        try:
            os.link(src, dst)                       # NTFS 硬链接：零拷贝、自动同步
            kind = "link"
        except OSError:
            shutil.copy2(src, dst)                  # 跨卷/权限退回复制
            kind = "copy"
        changed += 1
        if verbose:
            print(f"  {kind}: {rel}")
    if verbose:
        print(f"== 同步完成：{len(rels)} 个文件，更新 {changed} 个")
    return changed


# ---------------------------------------------------------------- 工具与环境

def build_env() -> dict:
    """构建编译器本身的环境：ZIG_LIB_DIR 必须用构建树自己的 lib。

    构建树的 src/lib 是打过补丁的（std 里有 mcs51/mcs251 与 McsInterruptOptions），
    而系统 zig 自带的 std 没有——用错会报
    'enum Target.Cpu.Arch has no member named mcs51'。
    """
    env = dict(os.environ)
    env["ZIG_LIB_DIR"] = str(BUILD_TREE / "lib")
    env["ZIG_GLOBAL_CACHE_DIR"] = str(GLOBAL_CACHE)
    env["ZIG_LOCAL_CACHE_DIR"] = str(LOCAL_CACHE)
    return env


def zig_env() -> dict:
    """跑 build-obj 所需环境：库目录与缓存同构建期保持一致。"""
    return build_env()


def sdcc_bin() -> Path:
    return Path(os.environ.get(
        "MCS_SDCC_BIN",
        WORKSPACE / "mcs251" / "tools" / "sdcc-mcs251-windows-x64" / "sdcc-mcs251" / "bin"))


def ucsim_exe() -> str:
    env = os.environ.get("UCSIM51")
    if env:
        return env
    cand = Path(r"C:/Program Files (x86)/SDCC/bin/ucsim_51.exe")
    if cand.exists():
        return str(cand)
    found = shutil.which("ucsim_51")
    if not found:
        raise SystemExit("找不到 ucsim_51：设置 UCSIM51 或把它加进 PATH")
    return found


def run(cmd, cwd=None, env=None, check=True) -> subprocess.CompletedProcess:
    printable = " ".join(str(c) for c in cmd)
    print("+", printable)
    r = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", check=False)
    if check and r.returncode != 0:
        print(r.stdout[-1500:] if r.stdout else "")
        print(r.stderr[-3000:] if r.stderr else "")
        raise SystemExit(f"命令失败（退出码 {r.returncode}）：{printable}")
    return r


# ---------------------------------------------------------------- 构建

def build(rebuild: bool = False) -> None:
    """同步源码并构建编译器。增量几秒；全量 2-3 分钟。"""
    if not (BUILD_TREE / "build.zig").exists():
        raise SystemExit(f"{BUILD_TREE} 里没有 build.zig——构建树不完整")
    sync()
    zig = shutil.which("zig")
    if not zig:
        raise SystemExit("找不到系统 zig（构建编译器要用它）")
    print(f"== 构建编译器：{BUILD_TREE}")
    if rebuild:
        print("   （--rebuild：先删 zig-out）")
        shutil.rmtree(BUILD_TREE / "zig-out", ignore_errors=True)
    run([zig, "build", "-Doptimize=Debug", "-Dversion-string=0.17.1"],
        cwd=BUILD_TREE, env=build_env())
    if not ZIG_EXE.exists():
        raise SystemExit(f"构建结束但没有产物：{ZIG_EXE}")
    print(f"== 编译器就绪：{ZIG_EXE}（{ZIG_EXE.stat().st_size // 1024} KB）")


def need_compiler() -> None:
    if not ZIG_EXE.exists():
        raise SystemExit(f"没有编译器产物 {ZIG_EXE}：先跑 python mcs2.py build")


# ---------------------------------------------------------------- 汇编/链接/仿真

def assemble(asm: Path, name: str, dseg: int, cseg: int = 0x0000) -> Path:
    from assemble51 import assemble as _assemble
    return _assemble(asm, BUILD, name, dseg_base=dseg, cseg_base=cseg)


def emit_asm(src: Path, tag: str) -> tuple[Path, str]:
    """zig build-obj -> 汇编文本。产物缺 CSEG 视为编译器异常。"""
    asm = BUILD / f"{tag}.asm"
    run([str(ZIG_EXE), "build-obj", "-OReleaseSmall", "-target", TARGET,
         "-femit-bin=" + str(asm), str(src)], env=zig_env())
    text = asm.read_text(encoding="utf-8")
    if ".area CSEG (CODE)" not in text:
        raise SystemExit(f"FAIL: {tag} 的汇编产物没有 CSEG 段")
    return asm, text


def merge(tag: str, driver: str, body: str) -> Path:
    out = BUILD / f"{tag}_full.asm"
    out.write_text(driver + body, encoding="utf-8", newline="\n")
    return out


def sim(ihx: Path, steps: int, slots: int = 4, base: int = 0x8000,
        extra: list[tuple[int, int]] | None = None) -> dict[int, int]:
    """跑 ucsim，dump xram（默认 0x8000 起 slots 个，可额外多段）。"""
    ranges = [(base, slots)] + list(extra or [])
    cmds = "set opt selfjump_stop 0\nstep %d\n" % steps
    for b, n in ranges:
        cmds += f"dump xram 0x{b:04X} 0x{b + n:04X}\n"
    cmds += "quit\n"
    r = subprocess.run([ucsim_exe(), "-t", "8052", str(ihx)],
                       input=cmds, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", check=False)
    values: dict[int, int] = {}
    for line in (r.stdout + r.stderr).splitlines():
        m = re.match(r"^\s*0x([0-9a-fA-F]{4})\s+((?:[0-9a-fA-F]{2}[ \t]+)+)", line)
        if not m:
            continue
        addr = int(m.group(1), 16)
        for k, tok in enumerate(m.group(2).split()):
            values[addr + k] = int(tok, 16)
    return values


def driver_call(fn: str, args: list[tuple[str, int]], slot: int = 0x8000,
                ret_bytes: int = 1) -> str:
    """摆参 -> lcall -> 结果写 xdata 槽 -> 停机。

    ret_bytes=1：返回值在 DPL，写一个字节。
    ret_bytes=2：返回值在 DPL(低)/DPH(高)，写两个字节（u16 ABI）。
    """
    out = "    .area CSEG (CODE)\n    mov sp,#0x7F\n"
    for pos, val in args:
        if pos in ("DPL", "DPH", "B", "ACC"):
            out += f"    mov {pos.lower()},#0x{val:02X}\n"
        elif pos == "SYM16":
            # 传一个符号的 16 位地址（拆低/高字节）——间接调用测试用
            out += f"    mov dpl,#<{val}\n    mov dph,#>{val}\n"
        elif pos == "PARM2":
            out += f"    mov _{fn}_PARM_2,#0x{val:02X}\n"
        elif pos.startswith("PARM_"):
            out += f"    mov _{fn}_{pos},#0x{val:02X}\n"
        else:
            raise SystemExit(f"未知参数位置 {pos}")
    regs = {1: ["dpl"], 2: ["dpl", "dph"], 4: ["dpl", "dph", "b", "acc"]}[ret_bytes]
    if ret_bytes == 1:
        # 先取 A 再建指针：mov dptr 会覆盖 DPL（返回值就在那里）。
        out += f"    lcall _{fn}\n    mov a,dpl\n    mov dptr,#0x{slot:04X}\n    movx @dptr,a\n"
    else:
        # 多字节返回在 DPL/DPH/B/A：先压栈保存（建指针会覆盖 DPL/DPH），再逐个写回。
        out += f"    lcall _{fn}\n"
        for reg in reversed(regs):
            out += f"    push {reg}\n"
        out += f"    mov dptr,#0x{slot:04X}\n"
        for _ in regs:
            out += "    pop 0xE0\n    movx @dptr,a\n    inc dptr\n"
    out += "    sjmp .\n"
    return out


# ---------------------------------------------------------------- 用例表

CASES: dict[str, dict] = {
    "add":     dict(kind="call", src="add.zig",      fn="add",    args=[("DPL", 3), ("PARM2", 4)], want=0x07),
    "varfn":   dict(kind="call", src="locals.zig",   fn="varfn",  args=[("DPL", 3)],                want=0x04),
    "addrfn":  dict(kind="call", src="locals.zig",   fn="addrfn", args=[("DPL", 5)],                want=0x06),
    "sum":     dict(kind="call", src="loop.zig",     fn="sum",    args=[("DPL", 5)],                want=10, steps=5000),
    "cnt":     dict(kind="call", src="loop.zig",     fn="cnt",    args=[("DPL", 7)],                want=7,  steps=5000),
    "sum_to_fold": dict(kind="call", src="loop.zig", fn="sum_to_fold", args=[],                     want=44, steps=5000),
    "big":     dict(kind="call", src="bigloop.zig",  fn="big",    args=[("DPL", 3)], want=90, steps=20000, dseg=0x08, want_ljmp=True),
    "interrupt": dict(kind="interrupt", src="interrupt.zig"),
    # 运行期 xdata 下标（UART RX 环前置）：写 buf[3]=0x43 再读回。
    "memrt":   dict(kind="call", src="mem.zig", fn="memrt", args=[("DPL", 3)], want=0x43,
                    expect_mem={0x8103: 0x43}),
    "bitfn":   dict(kind="call", src="mem.zig", fn="bitfn", args=[("DPL", 0xF5)], want=0x85),
    "xor2":    dict(kind="call", src="mem.zig", fn="xor2", args=[("DPL", 0xFF)], want=0x55),
    # cmp_br(ne) 的两种形态：与运行期值比 / 与立即数比（发射层 cjne）。
    "ne5":     dict(kind="call", src="mem.zig", fn="ne5", args=[("DPL", 5)], want=5, steps=2000),
    "ne_imm":  dict(kind="call", src="mem.zig", fn="ne_imm", args=[], want=3, steps=2000),
    # U2 位测试：SCON.1(TI) 的置位/清零轮询 → jb/jnb
    "bitpoll":  dict(kind="call", src="bit.zig", fn="bitpoll", args=[("DPL", 4)], want=4, steps=3000),
    "bitclear": dict(kind="call", src="bit.zig", fn="bitclear", args=[("DPL", 3)], want=3, steps=3000),
    # 移位与 SFR 单比特：<< / >> 走 rlc/rrc；|= 单比特 → setb，&= ~单比特 → clr
    "shl2":   dict(kind="call", src="shifts.zig", fn="shl2", args=[("DPL", 0x41)], want=0x04),
    "shr3":   dict(kind="call", src="shifts.zig", fn="shr3", args=[("DPL", 0xFF)], want=0x1F),
    "setbit": dict(kind="call", src="shifts.zig", fn="setbit", args=[], want=0x02),
    "clrbit": dict(kind="call", src="shifts.zig", fn="clrbit", args=[], want=0xFD),
    # 乘/除/取余/取反（MUL AB / DIV AB / CPL A）；xnor 验取反参与表达式
    "mul8":  dict(kind="call", src="math.zig", fn="mul8", args=[("DPL", 7), ("PARM2", 6)], want=42),
    "div8":  dict(kind="call", src="math.zig", fn="div8", args=[("DPL", 47), ("PARM2", 6)], want=7),
    "rem8":  dict(kind="call", src="math.zig", fn="rem8", args=[("DPL", 47), ("PARM2", 6)], want=5),
    "not8":  dict(kind="call", src="math.zig", fn="not8", args=[("DPL", 0x0F)], want=0xF0),
    "xnor8": dict(kind="call", src="math.zig", fn="xnor8", args=[("DPL", 0xF0), ("PARM2", 0x0F)], want=0x00),
    # u16（多字节模板）：参数/返回走 DPL/DPH，arg1 的字节落在 PARM_3/PARM_4
    "u16add":   dict(kind="call", src="multi.zig", fn="u16add",
                     args=[("DPL", 0x34), ("DPH", 0x12), ("PARM_2", 0xFF), ("PARM_3", 0x00)],
                     want16=0x1333),
    "u16sub":   dict(kind="call", src="multi.zig", fn="u16sub",
                     args=[("DPL", 0x34), ("DPH", 0x12), ("PARM_2", 0x10), ("PARM_3", 0x00)],
                     want16=0x1224),
    "u16carry": dict(kind="call", src="multi.zig", fn="u16carry", args=[("DPL", 1)], want16=0x0100),
    "u32add":   dict(kind="call", src="multi.zig", fn="u32add",
                     args=[("DPL", 0x78), ("DPH", 0x56), ("B", 0x34), ("ACC", 0x12),
                           ("PARM_2", 0xFF), ("PARM_3", 0x00), ("PARM_4", 0x00), ("PARM_5", 0x00)],
                     want32=0x12345777),   # 0x12345678 + 0x000000FF
    "u32carry": dict(kind="call", src="multi.zig", fn="u32carry", args=[("DPL", 1)], want32=0x00010000),
    "u16shl":   dict(kind="call", src="multi.zig", fn="u16shl", args=[("DPL", 0)], want16=0x0100),
    "u16shr":   dict(kind="call", src="multi.zig", fn="u16shr", args=[("DPL", 0)], want16=0x0080),
    # 有符号（i8/i16/i32）与多字节比较/位运算：符号扩展 + 算术右移 + 有符号比较
    "sexcmp":   dict(kind="call", src="signed.zig", fn="sexcmp", args=[("DPL", 0xFB)], want=1),
    "sexcmp2":  dict(kind="call", src="signed.zig", fn="sexcmp", args=[("DPL", 0x05)], want=0),
    "sex16":    dict(kind="call", src="signed.zig", fn="sex16",
                     args=[("DPL", 0x00), ("DPH", 0x80)], want32=0xFFFF8000),
    "i32add":   dict(kind="call", src="wide.zig", fn="i32add",
                     args=[("DPL", 0x00), ("DPH", 0x00), ("B", 0x00), ("ACC", 0x80),
                           ("PARM_2", 0xFF), ("PARM_3", 0xFF), ("PARM_4", 0xFF), ("PARM_5", 0xFF)],
                     want32=0x7FFFFFFF),
    "sar32":    dict(kind="call", src="sar.zig", fn="sar32",
                     args=[("DPL", 0xF0), ("DPH", 0xFF), ("B", 0xFF), ("ACC", 0xFF)],
                     want32=0xFFFFFFFE),
    "sar8":     dict(kind="call", src="sar.zig", fn="sar8", args=[("DPL", 0xF0)], want=0xFC),
    "ucmp_eq":  dict(kind="call", src="wide.zig", fn="ucmp32",
                     args=[("DPL", 0x00), ("DPH", 0x00), ("B", 0x01), ("ACC", 0x00)], want=2),
    "ucmp_gt":  dict(kind="call", src="wide.zig", fn="ucmp32",
                     args=[("DPL", 0xFF), ("DPH", 0xFF), ("B", 0x00), ("ACC", 0x00)], want=1),
    "ucmp_lt":  dict(kind="call", src="wide.zig", fn="ucmp32",
                     args=[("DPL", 0x01), ("DPH", 0x00), ("B", 0x01), ("ACC", 0x00)], want=3),
    "wbits":    dict(kind="call", src="wide.zig", fn="wbits",
                     args=[("DPL", 0x78), ("DPH", 0x56), ("B", 0x34), ("ACC", 0x12)],
                     want32=0xEDFFA90F),
    # 多字节乘法（固定模板）：16×16→16 走 3 次 MUL，32 位走 10 次 MUL
    "u16mul":  dict(kind="call", src="mul.zig", fn="u16mul",
                    args=[("DPL", 0x02), ("DPH", 0x01), ("PARM_2", 0x04), ("PARM_3", 0x03)],
                    want16=0x0A08),
    "u16mul2": dict(kind="call", src="mul.zig", fn="u16mul",
                    args=[("DPL", 0xFF), ("DPH", 0xFF), ("PARM_2", 0xFF), ("PARM_3", 0xFF)],
                    want16=0x0001),
    "i16mul":  dict(kind="call", src="mul.zig", fn="i16mul",
                    args=[("DPL", 0xFD), ("DPH", 0xFF), ("PARM_2", 0x05), ("PARM_3", 0x00)],
                    want16=0xFFF1),
    "u32mul":  dict(kind="call", src="mul32.zig", fn="u32mul",
                    args=[("DPL", 0x01), ("DPH", 0x00), ("B", 0x01), ("ACC", 0x00),
                          ("PARM_2", 0x01), ("PARM_3", 0x00), ("PARM_4", 0x01), ("PARM_5", 0x00)],
                    want32=0x00020001, steps=20000),
    # 多字节除法（恢复法循环）：u16/u32 商与余数、有符号商与余数
    "u16div":  dict(kind="call", src="div.zig", fn="u16div",
                    args=[("DPL", 0xE8), ("DPH", 0x03), ("PARM_2", 0x07), ("PARM_3", 0x00)],
                    want16=0x008E, steps=20000),
    "u16rem":  dict(kind="call", src="div.zig", fn="u16rem",
                    args=[("DPL", 0xE8), ("DPH", 0x03), ("PARM_2", 0x07), ("PARM_3", 0x00)],
                    want16=0x0006, steps=20000),
    "u32div":  dict(kind="call", src="div32.zig", fn="u32div",
                    args=[("DPL", 0x45), ("DPH", 0x23), ("B", 0x01), ("ACC", 0x00),
                          ("PARM_2", 0x00), ("PARM_3", 0x01), ("PARM_4", 0x00), ("PARM_5", 0x00)],
                    want32=0x00000123, steps=60000),
    "u32rem":  dict(kind="call", src="div32.zig", fn="u32rem",
                    args=[("DPL", 0x45), ("DPH", 0x23), ("B", 0x01), ("ACC", 0x00),
                          ("PARM_2", 0x00), ("PARM_3", 0x01), ("PARM_4", 0x00), ("PARM_5", 0x00)],
                    want32=0x00000045, steps=60000),
    "i32div":  dict(kind="call", src="sdiv.zig", fn="i32div",
                    args=[("DPL", 0x9C), ("DPH", 0xFF), ("B", 0xFF), ("ACC", 0xFF),
                          ("PARM_2", 0x07), ("PARM_3", 0x00), ("PARM_4", 0x00), ("PARM_5", 0x00)],
                    want32=0xFFFFFFF2, steps=60000),
    "i32rem":  dict(kind="call", src="sdiv.zig", fn="i32rem",
                    args=[("DPL", 0x9C), ("DPH", 0xFF), ("B", 0xFF), ("ACC", 0xFF),
                          ("PARM_2", 0x07), ("PARM_3", 0x00), ("PARM_4", 0x00), ("PARM_5", 0x00)],
                    want32=0xFFFFFFFE, steps=60000),
    "i8div":   dict(kind="call", src="sdiv8.zig", fn="i8div",
                    args=[("DPL", 0x9C), ("PARM2", 0x07)], want=0xF2, steps=5000),
    "i8rem":   dict(kind="call", src="sdiv8.zig", fn="i8rem",
                    args=[("DPL", 0x9C), ("PARM2", 0x07)], want=0xFE, steps=5000),
    "i16div":  dict(kind="call", src="sdiv8.zig", fn="i16div",
                    args=[("DPL", 0x18), ("DPH", 0xFC), ("PARM_2", 0x07), ("PARM_3", 0x00)],
                    want16=0xFF72, steps=20000),
    # 运行期移位次数（循环模板）：左移 / 逻辑右移 / 算术右移
    "shlv":   dict(kind="call", src="shiftv.zig", fn="shlv",
                   args=[("DPL", 0x01), ("DPH", 0x00), ("B", 0x00), ("ACC", 0x00), ("PARM2", 0x08)],
                   want32=0x00000100, steps=20000),
    "shrv":   dict(kind="call", src="shiftv.zig", fn="shrv",
                   args=[("DPL", 0x00), ("DPH", 0x00), ("B", 0x00), ("ACC", 0x80), ("PARM2", 0x04)],
                   want32=0x08000000, steps=20000),
    "shrv0":  dict(kind="call", src="shiftv.zig", fn="shrv",
                   args=[("DPL", 0x78), ("DPH", 0x56), ("B", 0x34), ("ACC", 0x12), ("PARM2", 0x00)],
                   want32=0x12345678, steps=20000),
    "sarv":   dict(kind="call", src="shiftv.zig", fn="sarv",
                   args=[("DPL", 0x00), ("DPH", 0xFF), ("B", 0xFF), ("ACC", 0xFF), ("PARM2", 0x04)],
                   want32=0xFFFFFFF0, steps=20000),
    # 比较当值用（bool 返回 0/1）
    "lt32":   dict(kind="call", src="cmpval.zig", fn="lt32",
                   args=[("DPL", 0xFF), ("DPH", 0xFF), ("B", 0xFF), ("ACC", 0xFF),
                         ("PARM_2", 0x00), ("PARM_3", 0x00), ("PARM_4", 0x00), ("PARM_5", 0x00)],
                   want=1),
    "lt32b":  dict(kind="call", src="cmpval.zig", fn="lt32",
                   args=[("DPL", 0x01), ("DPH", 0x00), ("B", 0x00), ("ACC", 0x00),
                         ("PARM_2", 0x00), ("PARM_3", 0x00), ("PARM_4", 0x00), ("PARM_5", 0x00)],
                   want=0),
    "ge8t":   dict(kind="call", src="cmpval.zig", fn="ge8", args=[("DPL", 5), ("PARM2", 5)], want=1),
    "ge8f":   dict(kind="call", src="cmpval.zig", fn="ge8", args=[("DPL", 4), ("PARM2", 5)], want=0),
    # M2.5 内部调用（call）：二参数 / u16 参数 / 4 字节 arg0 + PARM 溢出
    "chain":   dict(kind="call", src="calls.zig", fn="chain", args=[("DPL", 3)], want16=0x0018),
    "chain32": dict(kind="call", src="calls.zig", fn="chain32", args=[("DPL", 0x21)],
                    want32=0x12345621),
    "mix32":   dict(kind="call", src="calls.zig", fn="wide_mix",
                    args=[("DPL", 0x00), ("DPH", 0x56), ("B", 0x34), ("ACC", 0x12), ("PARM2", 0x21)],
                    want32=0x12345621),
    # 间接调用（函数指针）：地址装 u16 → @ptrFromInt → f(x)
    "call_ind": dict(kind="call", src="indcall.zig", fn="call_ind",
                     args=[("SYM16", "_inc8"), ("PARM2", 5)], want=6),
    "twice_ind": dict(kind="call", src="indcall.zig", fn="twice_ind",
                      args=[("SYM16", "_inc8"), ("PARM2", 5)], want=7),
    "call_addr": dict(kind="call", src="indcall.zig", fn="call_addr", args=[("DPL", 9)], want=10),
    # kfifo 式环形缓冲：u8 索引 + 掩码（and）替代取模。
    "ringdemo": dict(kind="call", src="ring.zig", fn="ringdemo", args=[("DPL", 5)], want=15, steps=5000),
}

ORDER = ["selftest", "add", "varfn", "addrfn", "sum", "cnt", "sum_to_fold", "big",
         "interrupt", "memrt", "bitfn", "xor2", "ne5", "ne_imm", "bitpoll", "bitclear",
         "shl2", "shr3", "setbit", "clrbit",
         "mul8", "div8", "rem8", "not8", "xnor8",
         "u16add", "u16sub", "u16carry", "u16shl", "u16shr", "u32add", "u32carry",
         "sexcmp", "sexcmp2", "sex16", "i32add", "sar32", "sar8",
         "ucmp_eq", "ucmp_gt", "ucmp_lt", "wbits",
         "u16mul", "u16mul2", "i16mul", "u32mul",
         "u16div", "u16rem", "u32div", "u32rem", "i32div", "i32rem", "i8div", "i8rem", "i16div",
         "shlv", "shrv", "shrv0", "sarv",
         "lt32", "lt32b", "ge8t", "ge8f",
         "chain", "chain32", "mix32",
         "call_ind", "twice_ind", "call_addr",
         "ringdemo"]


def check_selftest() -> bool:
    """MIR 发射器自检：跑 selftest.zig（汇编走 stderr），4 个 xram 点全对。"""
    zig = shutil.which("zig")
    if not zig:
        raise SystemExit("找不到系统 zig")
    selftest = SRC_TREE / "src" / "codegen" / "mcs2" / "selftest.zig"
    r = run([zig, "run", str(selftest)], cwd=HERE, env=build_env(), check=False)
    asm = (r.stderr or "") + (r.stdout or "")
    if ".area CSEG (CODE)" not in asm:
        print(asm[-1200:])
        print("FAIL: selftest 没有输出预期汇编")
        return False
    asm_path = BUILD / "out.asm"
    asm_path.write_text(asm, encoding="utf-8", newline="\n")
    ihx = assemble(asm_path, "out", dseg=0x08)
    got = sim(ihx, steps=400, slots=4)
    expect = {0x8000: 0x07, 0x8001: 0x01, 0x8002: 0x00, 0x8003: 0x01}
    ok = True
    for addr, want in expect.items():
        have = got.get(addr)
        flag = "PASS" if have == want else "FAIL"
        print(f"  {flag}: {addr:#06x} = {have if have is None else hex(have)}（期望 {hex(want)}）")
        ok = ok and have == want
    return ok


def check_call(name: str, spec: dict) -> bool:
    dseg = spec.get("dseg", 0x30)
    steps = spec.get("steps", 400)
    _, text = emit_asm(HERE / "tests" / spec["src"], name)
    if spec.get("want_ljmp") and "ljmp" not in text:
        print("FAIL: 期望长跳（ljmp）但产物里没有——跳转松弛没生效")
        return False
    want_wide = spec.get("want16") if spec.get("want16") is not None else spec.get("want32")
    ret_bytes = spec.get("ret_bytes", 1)
    if spec.get("want16") is not None:
        ret_bytes = 2
    if spec.get("want32") is not None:
        ret_bytes = 4
    merged = merge(name, driver_call(spec["fn"], spec["args"], ret_bytes=ret_bytes), text)
    ihx = assemble(merged, name, dseg=dseg)
    expect_mem: dict[int, int] = spec.get("expect_mem") or {}
    if want_wide is not None:
        # 多字节返回按低字节序写在 slot 起的位置
        expect_mem = {0x8000 + i: (want_wide >> (8 * i)) & 0xFF for i in range(ret_bytes)}
    extra = [(min(expect_mem), len(expect_mem))] if expect_mem else None
    got = sim(ihx, steps=steps, slots=1, extra=extra)
    ok = True
    if want_wide is None:
        val = got.get(0x8000)
        ok = val == spec["want"]
        print(f"  {'PASS' if ok else 'FAIL'}: {name} = {val}（期望 {spec['want']}）")
    for addr, want in expect_mem.items():
        have = got.get(addr)
        good = have == want
        print(f"  {'PASS' if good else 'FAIL'}: xdata {addr:#06x} = {have}（期望 {want}）")
        ok = ok and good
    if name == "sum_to_fold":
        pe_ok = "mov 0x82,#0x2C" in text     # 循环/比较全部消失，只剩常量写回 + ret
        print(f"  {'PASS' if pe_ok else 'FAIL'}: sum_to_fold 折叠成常量写回")
        ok = ok and pe_ok
    return ok


INTERRUPT_DRIVER = """\
    .area VECTORS (ABS,CODE)
    .org 0x0000
    ljmp _crt_main
    .area CSEG (CODE)
_crt_main:
    mov tmod,#0x01
    mov th0,#0xFF
    mov tl0,#0x38
    mov ie,#0x82
    orl 0x88,#0x10
    mov dptr,#0x8000
    mov a,#0x00
    movx @dptr,a
loop:
    inc r0
    sjmp loop
"""


def check_interrupt(name: str) -> bool:
    _, text = emit_asm(HERE / "tests" / "interrupt.zig", name)
    # ISR 必须真的保存/恢复现场并以 reti 结束（曾因 Lower.is_isr 漏赋值退化成 ret）。
    pushes = text.count("    push ")
    pops = text.count("    pop ")
    shape_ok = pushes > 0 and pushes == pops and "    reti" in text
    print(f"  {'PASS' if shape_ok else 'FAIL'}: ISR 现场保存/恢复（push {pushes} / pop {pops} / reti）")
    merged = merge(name, INTERRUPT_DRIVER + "\n", text)
    ihx = assemble(merged, name, dseg=0x30, cseg=0x0030)
    count = sim(ihx, steps=2000, slots=1)[0x8000]
    # ucsim 的中断重复投递不可靠（对代码布局敏感）：≥1 即中断通路成立，
    # 连续中断交给 QEMU(251)/实机。
    ok = count >= 1
    print(f"  {'PASS' if ok else 'FAIL'}: timer0 中断计数 = {count}（阈值 ≥1）")
    return ok and shape_ok


def size_gate() -> bool:
    """M1 尺寸门禁：_add 函数体 ≤ 27B（1.5 × 旧后端 add8 基线 18B）。"""
    lst = BUILD / "add.lst"
    if not lst.exists():
        print("  SKIP: 没有 add.lst（先跑 add 用例）")
        return True
    lines = lst.read_text(errors="replace").splitlines()
    idx = next((i for i, l in enumerate(lines) if "_add:" in l and ".globl" not in l), None)
    if idx is None:
        print("  FAIL: listing 里没有 _add")
        return False
    rows = []
    for line in lines[idx + 1:]:
        m = re.match(r"^\s*([0-9A-Fa-f]{4,6})\s+\S.*?\[\s*\d+\]\s+\d+\s+(.*)$", line)
        if m:
            rows.append((int(m.group(1), 16), m.group(2).strip()))
    start = rows[0][0] if rows else None
    end = next((a + 1 for a, t in rows if t.upper().startswith("RET")), None)
    if start is None or end is None:
        print("  FAIL: 解析不出 _add 函数体")
        return False
    n = end - start
    ok = n <= 27
    print(f"  {'PASS' if ok else 'FAIL'}: _add 尺寸 {n} B ≤ 27 B")
    return ok


def check(names: list[str]) -> int:
    need_compiler()
    BUILD.mkdir(parents=True, exist_ok=True)
    todo = names or ORDER
    failed = []
    for name in todo:
        print(f"== {name}")
        if name == "selftest":
            ok = check_selftest()
        elif name == "interrupt":
            ok = check_interrupt(name)
        elif name in CASES:
            ok = check_call(name, CASES[name])
        else:
            print(f"未知用例 {name}；可用：{', '.join(ORDER)}")
            return 2
        if not ok:
            failed.append(name)
    if "add" in todo and not failed:
        print("== 尺寸门禁")
        if not size_gate():
            failed.append("size")
    print()
    if failed:
        print(f"FAIL: {', '.join(failed)}")
        return 1
    print(f"PASS: 全部 {len(todo)} 项")
    return 0


# ---------------------------------------------------------------- 固件

FW_ENTRY = """\
    .area CSEG (CODE)
    ljmp _crt_main
_crt_main:
    mov sp,#0x7F
    lcall _main
    sjmp .
"""

FW = {
    "uart": dict(src="uart_demo.zig", name="uart_demo_8h8k64u", dseg=0x30, cseg=0x0000),
}


def firmware(which: str, tag: str = "") -> int:
    need_compiler()
    spec = FW.get(which)
    if not spec:
        print(f"未知固件 {which}；可用：{', '.join(FW)}")
        return 2
    BUILD.mkdir(parents=True, exist_ok=True)
    _, text = emit_asm(HERE / "tests" / spec["src"], spec["name"])
    merged = merge(spec["name"], FW_ENTRY, text)
    ihx = assemble(merged, spec["name"], dseg=spec["dseg"], cseg=spec["cseg"])
    # 产物放工作区 build/fw/（与既有固件同处，烧录脚本按目录找）
    out_dir = WORKSPACE / "build" / "fw"
    out_dir.mkdir(parents=True, exist_ok=True)
    suffix = f"_{tag}" if tag else ""
    final = out_dir / f"{spec['name']}{suffix}.ihx"
    shutil.copyfile(ihx, final)
    print(f"OK: {final}（{final.stat().st_size} B）")
    return 0


def clean() -> int:
    """删掉编译器缓存（下次构建全量 2-3 分钟，换来磁盘干净）。"""
    freed = 0
    for d in (GLOBAL_CACHE, LOCAL_CACHE):
        if d.exists():
            for f in d.rglob("*"):
                if f.is_file():
                    try:
                        freed += f.stat().st_size
                    except OSError:
                        pass
            shutil.rmtree(d, ignore_errors=True)
            print(f"  已删 {d}")
        else:
            print(f"  跳过 {d}（不存在）")
    print(f"== 释放 {freed / 1024 / 1024:.0f} MB；下次 build 为全量")
    return 0


def doctor() -> int:
    """体检：工具与产物各在哪、缺什么。一条命令回答“环境对不对”。"""
    def line(name, target, ok, extra=""):
        mark = "OK  " if ok else "缺失"
        print(f"  [{mark}] {name:<14} {target}{('  ' + extra) if extra else ''}")

    zig = shutil.which("zig")
    line("系统 zig", zig or "-", bool(zig))
    bindir = sdcc_bin()
    for t in ("sdas8051.exe", "sdld.exe"):
        q = bindir / t
        line(t, q, q.exists())
    try:
        line("ucsim_51", ucsim_exe(), True)
    except SystemExit:
        line("ucsim_51", "(未找到；设 UCSIM51)", False)
    line("构建树", BUILD_TREE, (BUILD_TREE / "build.zig").exists())
    line("编译器", ZIG_EXE, ZIG_EXE.exists(),
         f"{ZIG_EXE.stat().st_size // 1024} KB" if ZIG_EXE.exists() else "")
    # 同步状态：源码与构建树是否已经是同一个文件
    rels = list(SYNC_FILES) + [str(q.relative_to(SRC_TREE)) for q in sorted(SRC_TREE.glob(SYNC_GLOB))]
    unlinked = []
    for rel in rels:
        src, dst = SRC_TREE / rel, BUILD_TREE / rel
        if not dst.exists():
            unlinked.append(rel)
            continue
        try:
            if not os.path.samefile(src, dst):
                unlinked.append(rel)
        except OSError:
            unlinked.append(rel)
    line("源码同步", f"{len(rels) - len(unlinked)}/{len(rels)} 个已硬链接",
         not unlinked, ("待同步：" + ", ".join(unlinked)) if unlinked else "")
    return 0


# ---------------------------------------------------------------- CLI

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="mcs2.py", description="mcs2 唯一入口")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("sync", help="把源码硬链接进构建树（幂等）")

    p_build = sub.add_parser("build", help="同步源码并构建编译器")
    p_build.add_argument("--rebuild", action="store_true", help="先删 zig-out 再全量构建")

    p_check = sub.add_parser("check", help="跑仿真验收")
    p_check.add_argument("cases", nargs="*", help=f"用例名（默认全部）：{', '.join(ORDER)}")

    p_fw = sub.add_parser("fw", help="生成实机固件")
    p_fw.add_argument("which", nargs="?", default="uart", help="固件名（默认 uart）")
    p_fw.add_argument("--tag", default="", help="文件名后缀，如 45.1584M_9600（记录时钟/波特率）")

    sub.add_parser("doctor", help="体检：工具与产物位置、源码是否已同步")
    sub.add_parser("clean", help="删除编译器缓存（下次构建全量）")
    sub.add_parser("all", help="build + check")

    args = parser.parse_args(argv)
    if args.cmd == "sync":
        sync()
        return 0
    if args.cmd == "build":
        build(rebuild=args.rebuild)
        return 0
    if args.cmd == "check":
        return check(args.cases)
    if args.cmd == "fw":
        return firmware(args.which, args.tag)
    if args.cmd == "doctor":
        return doctor()
    if args.cmd == "clean":
        return clean()
    if args.cmd == "all":
        build()
        return check([])
    return 2


if __name__ == "__main__":
    sys.exit(main())
