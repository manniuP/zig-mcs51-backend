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

# Windows 控制台/管道的默认编码是 GBK，中文在 UTF-8 查看器里就是乱码（白方块）。
# 这里把本工具的 stdout/stderr 统一强制成 UTF-8：日志、管道、终端都是同一份字节。
# （realcheck / bench_compare / fwsize 都 import 本模块，一并生效。）
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

HERE = Path(__file__).resolve().parent            # zig-0.17/tools/mcs2
SRC_TREE = HERE.parents[1]                         # zig-0.17：源码真源
WORKSPACE = HERE.parents[2]
BUILD_TREE = WORKSPACE / "zig017" / "mcs2build"    # 编译器构建树（带补丁的 src/lib）
CACHE = WORKSPACE / "zig017"                       # 缓存集中在这里，不污染源码树
GLOBAL_CACHE = CACHE / "cache-mcs2"
LOCAL_CACHE = CACHE / "cache-mcs2-local"
BUILD = HERE / "build"
# 用例与定点库都放在 examples/mcs51/（统一由那里的 build.zig 构建）：
#   examples/mcs51/src/*.zig   —— 每个文件一组用例
#   examples/mcs51/lib/cordic.zig —— @import("cordic") 的定点数学库
EXAMPLES = SRC_TREE / "examples" / "mcs51"
TESTS = EXAMPLES / "src"
CORDIC = EXAMPLES / "lib" / "cordic.zig"
ZIG_EXE = BUILD_TREE / "zig-out" / "bin" / "zig.exe"
TARGET = "mcs51-freestanding"

if os.environ.get("ZIG017"):                       # 兼容旧习惯：显式指定编译器
    ZIG_EXE = Path(os.environ["ZIG017"])

# 需要保持两处一致的文件（相对源码树）
SYNC_FILES = [
    "src/codegen/mcs2.zig",
    # 链接层：全局变量/const 表的数据发射（.db）也归我们改
    "src/link/Asx.zig",
    # 宿主链接（COFF）：weak external 的宽松解析，修自举 build runner 的解析失败
    "src/link/Coff.zig",
]
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

def build(rebuild: bool = False, release: bool = False) -> None:
    """同步源码并构建编译器。增量几秒；全量 2-3 分钟。

    `release=True`（或环境变量 MCS2_RELEASE=1）用 ReleaseFast：
    Debug 版带 SafeAllocator 的泄漏检查，会把编译器内部（上游）的"leaked"刷到 stderr；
    日常用（尤其想让本编译器自己跑 `zig build`）用 ReleaseFast 更干净也更快。
    """
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
    opt = "ReleaseFast" if (release or os.environ.get("MCS2_RELEASE") == "1") else "Debug"
    print(f"   （optimize={opt}）")
    run([zig, "build", f"-Doptimize={opt}", "-Dversion-string=0.17.1"],
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


def emit_asm(src: Path, tag: str, opt: str = "ReleaseSmall") -> tuple[Path, str]:
    """zig build-obj -> 汇编文本。产物缺 CSEG 视为编译器异常。

    默认尺寸档；安全档用例传 opt="ReleaseSafe"，用来验溢出检查与停机路径。
    固定注入命名模块 `cordic`（= tools/mcs2/lib/cordic.zig）：用例里 `@import("cordic")`
    就能用定点数学库；不 import 的用例不受影响（模块不会被分析）。
    """
    asm = BUILD / f"{tag}.asm"
    run([str(ZIG_EXE), "build-obj", f"-O{opt}", "-target", TARGET,
         "--dep", "cordic", f"-Mroot={src}", f"-Mcordic={CORDIC}",
         "-femit-bin=" + str(asm)], env=zig_env())
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
                ret_bytes: int = 1, sentinel: int | None = None) -> str:
    """摆参 -> lcall -> 结果写 xdata 槽 -> 停机。

    ret_bytes=1：返回值在 DPL，写一个字节。
    ret_bytes=2：返回值在 DPL(低)/DPH(高)，写两个字节（u16 ABI）。
    sentinel：调用前先把结果槽写成该值。安全档溢出时后端停机、不写结果，
    槽里就还是哨兵；正常返回则被结果覆盖。用来区分「停机」与「算出 0」。
    """
    out = "    .area CSEG (CODE)\n    mov sp,#0x7F\n"
    if sentinel is not None:
        out += f"    mov dptr,#0x{slot:04X}\n"
        for _k in range(ret_bytes):
            out += (f"    mov a,#0x{sentinel:02X}\n"
                    "    movx @dptr,a\n"
                    "    inc dptr\n")
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
                     want32=0xFFFFFFFE, want_rt=1, rt_sym="_mcs_rt_sar32"),
    # 同一家族的另外两份模板：逻辑右移 / 左移（含跨字节进位）
    "shr32t": dict(kind="call", src="sar.zig", fn="shr32t",
                   args=[("DPL", 0x00), ("DPH", 0x00), ("B", 0x00), ("ACC", 0x80)],
                   want32=0x08000000, want_rt=1, rt_sym="_mcs_rt_shr32"),
    "shl32t": dict(kind="call", src="sar.zig", fn="shl32t",
                   args=[("DPL", 0x78), ("DPH", 0x56), ("B", 0x34), ("ACC", 0x12)],
                   want32=0x23456780, want_rt=1, rt_sym="_mcs_rt_shl32"),
    "shl32c": dict(kind="call", src="sar.zig", fn="shl32c",
                   args=[("DPL", 0xFF), ("DPH", 0x00), ("B", 0x00), ("ACC", 0x00)],
                   want32=0x0000FF00, want_rt=1, rt_sym="_mcs_rt_shl32"),
    # 运行期移位次数：必须仍走内联循环（次数进 r0 时 djnz 先减后判，0 会转 256 次）。
    "sar32v":   dict(kind="call", src="rtvar.zig", fn="sar32v",
                     args=[("DPL", 0xBE), ("DPH", 0xBA), ("B", 0xFE), ("ACC", 0xCA),
                           ("PARM2", 11)],
                     want32=0xFFF95FD7, want_no_rt=True),
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
    # 命令分发（语句形态 switch）：enum 选分支 + 统一参数/返回
    "dispatch": dict(kind="call", src="switchd.zig", fn="dispatch", args=[("DPL", 2)], want=0x22),
    # 固定地址的多字节读写（u32 @ 0x8000）
    "wstore": dict(kind="call", src="xdata32.zig", fn="wstore",
                   args=[("DPL", 0x78), ("DPH", 0x56), ("B", 0x34), ("ACC", 0x12)],
                   want=None, expect_mem={0x8100: 0x78, 0x8101: 0x56, 0x8102: 0x34, 0x8103: 0x12}),
    "wround": dict(kind="call", src="xdata32.zig", fn="wround",
                   args=[("DPL", 0xFE), ("DPH", 0xFF), ("B", 0xFF), ("ACC", 0xFF)],
                   want32=0xFFFFFFFF),   # v = 0xFFFFFFFE，+1 → 0xFFFFFFFF
    "wround2": dict(kind="call", src="xdata32.zig", fn="wround2",
                    args=[("DPL", 0x78), ("DPH", 0x56), ("B", 0x34), ("ACC", 0x12)],
                    want32=0x12345678),
    "addone": dict(kind="call", src="xdata32.zig", fn="addone",
                   args=[("DPL", 0x78), ("DPH", 0x56), ("B", 0x34), ("ACC", 0x12)],
                   want32=0x12345679),
    # 运行期下标 + 多字节元素（u16 表）；u8 表作对照
    # 运行期下标 + 多字节元素（u16 表；scale=2）；u8 表作对照
    "t16rt": dict(kind="call", src="tableidx.zig", fn="t16rt",
                  args=[("DPL", 3), ("PARM_2", 0x34), ("PARM_3", 0x12)], want16=0x1234),
    "t8rt": dict(kind="call", src="tableidx.zig", fn="t8rt",
                 args=[("DPL", 5), ("PARM2", 0xA5)], want=0xA5),
    "t16pair": dict(kind="call", src="tableidx.zig", fn="t16pair",
                    args=[("DPL", 3), ("PARM_2", 0x11), ("PARM_3", 0x11),
                          ("PARM_4", 0x22), ("PARM_5", 0x22)], want16=0x3333, steps=3000),
    "t8pair": dict(kind="call", src="tableidx.zig", fn="t8pair",
                   args=[("DPL", 5), ("PARM2", 0x11), ("PARM_3", 0x22)], want=0x33, steps=1000),
    "t32rt": dict(kind="call", src="tableu32.zig", fn="t32rt",
                  args=[("DPL", 3), ("PARM_2", 0x78), ("PARM_3", 0x56),
                        ("PARM_4", 0x34), ("PARM_5", 0x12)], want32=0x12345678, steps=3000),
    # 三维数组：屏幕帧缓冲 fb[page][row][col]（步长 4096 / 128 / 2）
    "fb3d": dict(kind="call", src="fb3d.zig", fn="px",
                 args=[("DPL", 1), ("PARM_2", 5), ("PARM_3", 7), ("PARM_4", 0xEF), ("PARM_5", 0xBE)],
                 want16=0xBEEF, steps=8000),
    # 全局三维数组（符号基址）
    "gfb": dict(kind="call", src="fb3d.zig", fn="gpx",
                args=[("DPL", 1), ("PARM_2", 3), ("PARM_3", 9), ("PARM_4", 0x34), ("PARM_5", 0x12)],
                want16=0x1234, steps=8000),
    # 同一缓冲的两种寻址互相验证（多维 vs 平面），不对就非 0
    "fbchk": dict(kind="call", src="fb3d.zig", fn="pxchk",
                  args=[("DPL", 1), ("PARM_2", 5), ("PARM_3", 7), ("PARM_4", 0xEF), ("PARM_5", 0xBE)],
                  want16=0x0000, steps=12000),
    # 运行期指针做基址：p[i] 的 p 是参数/指针变量
    "p2d": dict(kind="call", src="ptrrt.zig", fn="p2d",
                args=[("DPL", 0x00), ("DPH", 0x81), ("PARM_2", 2), ("PARM_3", 3), ("PARM_4", 0xC3)],
                want=0xC3, steps=6000),
    "pprt": dict(kind="call", src="ptrrt.zig", fn="pprt",
                 args=[("DPL", 0x00), ("DPH", 0x81), ("PARM_2", 5), ("PARM_3", 0xA5)],
                 want=0xA5, steps=4000),
    # scale=2：u16 元素 + 运行期基址（base + i*2 的进位要进 DPH）
    "pu16": dict(kind="call", src="ptrrt.zig", fn="pu16",
                 args=[("DPL", 0x00), ("DPH", 0x81), ("PARM_2", 3),
                       ("PARM_3", 0x34), ("PARM_4", 0x12)],
                 want16=0x1234, steps=6000),
    # 尾递归：自递归（变循环）+ 互递归（ljmp 到另一个函数），栈不增长
    "trsum": dict(kind="call", src="tailrec.zig", fn="trsum", args=[("DPL", 5)], want16=15, steps=20000),
    "trev": dict(kind="call", src="tailrec.zig", fn="evodd", args=[("DPL", 4)], want=1, steps=20000),
    "trod": dict(kind="call", src="tailrec.zig", fn="evodd", args=[("DPL", 5)], want=0, steps=20000),
    # 多字节全局变量：写进 var g: u32 / u16，再从**另一个函数**读回
    "wg32": dict(kind="call", src="gwide.zig", fn="wg32",
                 args=[("DPL", 0x78), ("DPH", 0x56), ("B", 0x34), ("ACC", 0x12)],
                 want32=0x12345678, steps=4000),
    "wg16": dict(kind="call", src="gwide.zig", fn="wg16",
                 args=[("DPL", 0x34), ("DPH", 0x12)], want16=0x1234, steps=3000),
    # 全局 u32 的读-改-写 / 参与宽比较
    "wginc": dict(kind="call", src="gwide.zig", fn="wginc",
                  args=[("DPL", 0x00), ("DPH", 0x10), ("B", 0x00), ("ACC", 0x00),
                        ("PARM_2", 0x34), ("PARM_3", 0x02), ("PARM_4", 0x00), ("PARM_5", 0x00)],
                  want32=0x1234, steps=8000),
    "wgcmp1": dict(kind="call", src="gwide.zig", fn="wgcmp",
                   args=[("DPL", 0x35), ("DPH", 0x12), ("B", 0x00), ("ACC", 0x00)],
                   want=1, steps=4000),
    "wgcmp0": dict(kind="call", src="gwide.zig", fn="wgcmp",
                   args=[("DPL", 0x34), ("DPH", 0x12), ("B", 0x00), ("ACC", 0x00)],
                   want=0, steps=4000),
    # arg0 是 32 位（第 3 字节在 B）→ 乘 scale 前必须保护 B，否则 x>>16 被踩坏
    "bscale": dict(kind="call", src="btable.zig", fn="bscale",
                   args=[("DPL", 0x56), ("DPH", 0x34), ("B", 0x12), ("ACC", 0x00), ("PARM_2", 3)],
                   want16=0x3468, steps=4000),
    "t32pair": dict(kind="call", src="tableu32.zig", fn="t32pair",
                    args=[("DPL", 3), ("PARM_2", 0x11), ("PARM_3", 0x11), ("PARM_4", 0x11), ("PARM_5", 0x11),
                          ("PARM_6", 0x22), ("PARM_7", 0x22), ("PARM_8", 0x22), ("PARM_9", 0x22)],
                    # scale=4 × 4 字节 × 2 元素 × 2（写+读）≈ 16 次 xdata 访问，
                    # 每次约 30 条指令；默认 400 步会半路截断（曾误判成「高字节错」）
                    want32=0x33333333, steps=8000),
    # 全局数组（符号基址，mov dptr,#_sym）：常量下标 / 运行期下标 / u8 / 相邻两元素
    "symconst": dict(kind="call", src="symtab.zig", fn="symconst",
                     args=[("DPL", 0x34), ("DPH", 0x12)], want16=0x1234, steps=3000),
    "symrt": dict(kind="call", src="symtab.zig", fn="symrt",
                  args=[("DPL", 1), ("PARM_2", 0xEF), ("PARM_3", 0xBE)], want16=0xBEEF, steps=3000),
    "symb": dict(kind="call", src="symtab.zig", fn="symb",
                 args=[("DPL", 2), ("PARM2", 0x5A)], want=0x5A, steps=2000),
    "sympair": dict(kind="call", src="symtab.zig", fn="sympair",
                    args=[("DPL", 1), ("PARM_2", 0x11), ("PARM_3", 0x11),
                          ("PARM_4", 0x22), ("PARM_5", 0x22)], want16=0x3333, steps=6000),
    # `@intFromPtr(&数据)`：地址本身变成 16 位值（DMA 描述符 / 缓冲区指针表）
    "daddr0": dict(kind="call", src="daddr.zig", fn="daddr0", args=[],
                   want=0x33, steps=4000),
    "daddr1": dict(kind="call", src="daddr.zig", fn="daddr1", args=[("DPL", 3)],
                   want=0x5A, steps=4000),
    "daddr2": dict(kind="call", src="daddr.zig", fn="daddr2", args=[("DPL", 1)],
                   want=0x5D, steps=6000),
    "daddr3": dict(kind="call", src="daddr.zig", fn="daddr3", args=[],
                   want=0x02, steps=4000),
    # 宽局部量（u16/u32 局部必须占够槽）
    "wloc1": dict(kind="call", src="wide3.zig", fn="wloc1",
                  args=[("DPL", 0x34), ("DPH", 0x12), ("PARM_2", 0x20), ("PARM_3", 0x00)],
                  want16=0x1255, steps=4000),
    "wloc2": dict(kind="call", src="wide3.zig", fn="wloc2",
                  args=[("DPL", 0x34), ("DPH", 0x12), ("PARM_2", 0x02), ("PARM_3", 0x00)],
                  want32=0x00031234, steps=8000),
    # 16/32 位运行期移位次数（8 位已有 shlv/shrv/sarv）
    "s16r": dict(kind="call", src="shift16.zig", fn="s16r",
                 args=[("DPL", 0xF8), ("DPH", 0xFF), ("PARM2", 1)], want16=0xFFFC, steps=4000),
    "u16l": dict(kind="call", src="shift16.zig", fn="u16l",
                 args=[("DPL", 0x21), ("DPH", 0x43), ("PARM2", 4)], want16=0x3210, steps=4000),
    "u32l": dict(kind="call", src="shift16.zig", fn="u32l",
                 args=[("DPL", 0x01), ("DPH", 0x00), ("B", 0x00), ("ACC", 0x00), ("PARM2", 8)],
                 want32=0x00000100, steps=8000),
    # CORDIC 定点数学库（lib/cordic.zig）：sin/cos/atan2/sqrt/hypot
    "csin90": dict(kind="call", src="cordic_sin.zig", fn="csin90", args=[], want16=0x3FFF, steps=30000),
    "csin45": dict(kind="call", src="cordic_sin.zig", fn="csin45", args=[], want16=0x2D42, steps=30000),
    "csin180": dict(kind="call", src="cordic_sin.zig", fn="csin180", args=[], want16=0x0005, steps=30000),
    "ccos0": dict(kind="call", src="cordic_cos.zig", fn="ccos0", args=[], want16=0x3FFF, steps=30000),
    "cat90": dict(kind="call", src="cordic_atan.zig", fn="cat90", args=[], want16=0x4003, steps=30000),
    "cat45": dict(kind="call", src="cordic_atan.zig", fn="cat45", args=[], want16=0x2001, steps=30000),
    # sqrt32 / hypot：DSEG 79 B；跨函数 skip 标签撞号已改由模块级保留编号段分配。
    "csqrt1m": dict(kind="call", src="cordic_sqrt.zig", fn="csqrt1m", args=[], want16=1000, steps=20000),
    "chyp": dict(kind="call", src="cordic_sqrt.zig", fn="chyp", args=[], want16=5, steps=20000),
    # if / switch 表达式（块返回值，内存 phi）
    "ifx1": dict(kind="call", src="ifexpr.zig", fn="ifx", args=[("DPL", 1)], want=0x11, steps=1000),
    "ifx0": dict(kind="call", src="ifexpr.zig", fn="ifx", args=[("DPL", 0)], want=0x22, steps=1000),
    "ifr1": dict(kind="call", src="ifexpr.zig", fn="ifr", args=[("DPL", 1)], want=0x11, steps=1000),
    "ifr0": dict(kind="call", src="ifexpr.zig", fn="ifr", args=[("DPL", 0)], want=0x22, steps=1000),
    "swx2": dict(kind="call", src="ifexpr.zig", fn="swx", args=[("DPL", 2)], want=0x22, steps=1500),
    "swx9": dict(kind="call", src="ifexpr.zig", fn="swx", args=[("DPL", 9)], want=0xEE, steps=1500),
    "ifw1": dict(kind="call", src="ifexpr.zig", fn="ifw", args=[("DPL", 1)], want16=0x1234, steps=1500),
    "ifw0": dict(kind="call", src="ifexpr.zig", fn="ifw", args=[("DPL", 0)], want16=0x5678, steps=1500),
    # 真 switch：语句形态（多 case / 范围 / else / enum 判定）
    "sw1h": dict(kind="call", src="switchex.zig", fn="sw1", args=[("DPL", 2)], want=0x22, steps=1000),
    "sw1m": dict(kind="call", src="switchex.zig", fn="sw1", args=[("DPL", 9)], want=0xEE, steps=1000),
    "sw2r": dict(kind="call", src="switchex.zig", fn="sw2", args=[("DPL", 4)], want=0x55, steps=1000),
    "sw2h": dict(kind="call", src="switchex.zig", fn="sw2", args=[("DPL", 8)], want=0x88, steps=1000),
    "sw2e": dict(kind="call", src="switchex.zig", fn="sw2", args=[("DPL", 7)], want=0xFF, steps=1000),
    "sw3a": dict(kind="call", src="switchex.zig", fn="sw3", args=[("DPL", 1)], want=0x01, steps=1000),
    "sw3b": dict(kind="call", src="switchex.zig", fn="sw3", args=[("DPL", 9)], want=0x09, steps=1000),
    # const 表（代码段 .db + movc）：常量下标 / 运行期下标 / u16 元素
    "cget2": dict(kind="call", src="consttab.zig", fn="cget2", args=[], want=0x33, steps=1000),
    "cgeti": dict(kind="call", src="consttab.zig", fn="cgeti", args=[("DPL", 5)], want=0x66, steps=1000),
    "wgeti": dict(kind="call", src="consttab.zig", fn="wgeti",
                  args=[("DPL", 1)], want16=0x3344, steps=2000),
    # 多维 const 表（GRID[i][j]）：链式地址 + movc
    "g2":  dict(kind="call", src="consttab.zig", fn="g2",
                args=[("DPL", 2), ("PARM2", 3)], want=0x23, steps=2000),
    "g2c": dict(kind="call", src="consttab.zig", fn="g2c", args=[("DPL", 1)], want=0x12, steps=2000),
    "g2r": dict(kind="call", src="consttab.zig", fn="g2r", args=[("DPL", 2)], want=0x32, steps=2000),
    # 函数指针表：填表（@intFromPtr）+ table[i] + @ptrFromInt + 间接调用
    "fpt_all": dict(kind="call", src="fptab.zig", fn="fpt_all",
                    args=[("DPL", 10)], want=0x14, steps=10000),
    # 调用踩 DPL：arg0 就地住 DPL 时，lcall 之后再用参数必须还是原值
    "argcall1": dict(kind="call", src="argcall.zig", fn="twice", args=[("DPL", 0x34)], want=0x6A, steps=2000),
    "argcall2": dict(kind="call", src="argcall.zig", fn="digits", args=[("DPL", 0x34)], want=0x09, steps=2000),
    "argcall3": dict(kind="call", src="argcall.zig", fn="after", args=[("DPL", 0x34)], want=0x69, steps=2000),
    # kfifo 式环形缓冲：u8 索引 + 掩码（and）替代取模。
    "ringdemo": dict(kind="call", src="ring.zig", fn="ringdemo", args=[("DPL", 5)], want=15, steps=5000),

    # ---- 安全档（ReleaseSafe）溢出检查 ----
    # 溢出用例用哨兵判停机：调用前把结果槽写成 0x55，正常返回会覆盖它，
    # 溢出停机则保持 0x55。尺寸档不编这些用例（那里本就不该有检查）。
    "safe_add_ok": dict(kind="call", src="safe.zig", fn="safe_add", args=[("DPL", 3), ("PARM2", 4)], want=0x07, opt="ReleaseSafe"),
    "safe_add_ov": dict(kind="call", src="safe.zig", fn="safe_add", args=[("DPL", 250), ("PARM2", 10)], want=0x55, opt="ReleaseSafe", sentinel=0x55, expect_mem={0x8100: 0x5A}),
    "safe_sub_ok": dict(kind="call", src="safe.zig", fn="safe_sub", args=[("DPL", 10), ("PARM2", 3)], want=0x07, opt="ReleaseSafe"),
    "safe_sub_ov": dict(kind="call", src="safe.zig", fn="safe_sub", args=[("DPL", 3), ("PARM2", 10)], want=0x55, opt="ReleaseSafe", sentinel=0x55, expect_mem={0x8100: 0x5A}),
    "safe_mul_ok": dict(kind="call", src="safe.zig", fn="safe_mul", args=[("DPL", 3), ("PARM2", 4)], want=0x0C, opt="ReleaseSafe"),
    "safe_mul_ov": dict(kind="call", src="safe.zig", fn="safe_mul", args=[("DPL", 20), ("PARM2", 20)], want=0x55, opt="ReleaseSafe", sentinel=0x55, expect_mem={0x8100: 0x5A}),
    # 16 位无符号：300*200=60000 正常；300*300=90000 溢出 → 停机（0x5A）
    "safe_mul16_ok": dict(kind="call", src="safemul.zig", fn="safe_mul16",
                          args=[("DPL", 0x2C), ("DPH", 0x01), ("PARM_2", 0xC8), ("PARM_3", 0x00)],
                          want16=60000, opt="ReleaseSafe", steps=4000),
    "safe_mul16_ov": dict(kind="call", src="safemul.zig", fn="safe_mul16",
                          args=[("DPL", 0x2C), ("DPH", 0x01), ("PARM_2", 0x2C), ("PARM_3", 0x01)],
                          want16=0x5555, opt="ReleaseSafe", sentinel=0x55,
                          expect_mem={0x8100: 0x5A}, steps=4000),
    # 32 位无符号：mulFull 拿 64 位积，高 32 位判零。
    # 0xFFFF*0xFFFF = 0xFFFE0001 是最大不溢出的边界。
    "safe_mul32_max": dict(kind="call", src="safemul32.zig", fn="safe_mul32",
                           args=[("DPL", 0xFF), ("DPH", 0xFF), ("B", 0x00), ("ACC", 0x00),
                                 ("PARM_2", 0xFF), ("PARM_3", 0xFF), ("PARM_4", 0x00), ("PARM_5", 0x00)],
                           want32=0xFFFE0001, opt="ReleaseSafe", steps=20000),
    "safe_mul32_ok": dict(kind="call", src="safemul32.zig", fn="safe_mul32",
                          args=[("DPL", 0xE8), ("DPH", 0x03), ("B", 0x00), ("ACC", 0x00),
                                ("PARM_2", 0xE8), ("PARM_3", 0x03), ("PARM_4", 0x00), ("PARM_5", 0x00)],
                          want32=1000000, opt="ReleaseSafe", steps=20000),
    # 0x10000 * 0x10000 = 2^32：低 32 位全零，唯一能抓住它的就是高位判据。
    "safe_mul32_ov": dict(kind="call", src="safemul32.zig", fn="safe_mul32",
                          args=[("DPL", 0x00), ("DPH", 0x00), ("B", 0x01), ("ACC", 0x00),
                                ("PARM_2", 0x00), ("PARM_3", 0x00), ("PARM_4", 0x01), ("PARM_5", 0x00)],
                          want32=0x55555555, opt="ReleaseSafe", sentinel=0x55,
                          expect_mem={0x8100: 0x5A}, steps=20000),
    # 判据不能误报：乘 1 保持原值，以及「小乘大」这类中间值接近上限的情形。
    "safe_mul32_one": dict(kind="call", src="safemul32.zig", fn="safe_mul32",
                           args=[("DPL", 0xFF), ("DPH", 0xFF), ("B", 0xFF), ("ACC", 0xFF),
                                 ("PARM_2", 0x01), ("PARM_3", 0x00), ("PARM_4", 0x00), ("PARM_5", 0x00)],
                           want32=0xFFFFFFFF, opt="ReleaseSafe", steps=20000),
    "safe_mul32_big": dict(kind="call", src="safemul32.zig", fn="safe_mul32",
                           args=[("DPL", 0xFF), ("DPH", 0xFF), ("B", 0x00), ("ACC", 0x00),
                                 ("PARM_2", 0x00), ("PARM_3", 0x00), ("PARM_4", 0x01), ("PARM_5", 0x00)],
                           want32=0xFFFF0000, opt="ReleaseSafe", steps=20000),
    # 有符号乘法：绝对值走无符号判据，再按结果符号卡边界。
    # i32：-2*3 正常；INT32_MIN*1 合法；INT32_MIN*-1 与 2^32 都溢出。
    "safe_imul32_ok": dict(kind="call", src="safemul32i.zig", fn="safe_imul32",
                           args=[("DPL", 0xFE), ("DPH", 0xFF), ("B", 0xFF), ("ACC", 0xFF),
                                 ("PARM_2", 0x03), ("PARM_3", 0x00), ("PARM_4", 0x00), ("PARM_5", 0x00)],
                           want32=0xFFFFFFFA, opt="ReleaseSafe", steps=20000),
    "safe_imul32_min": dict(kind="call", src="safemul32i.zig", fn="safe_imul32",
                            args=[("DPL", 0x00), ("DPH", 0x00), ("B", 0x00), ("ACC", 0x80),
                                  ("PARM_2", 0x01), ("PARM_3", 0x00), ("PARM_4", 0x00), ("PARM_5", 0x00)],
                            want32=0x80000000, opt="ReleaseSafe", steps=20000),
    "safe_imul32_ov_min": dict(kind="call", src="safemul32i.zig", fn="safe_imul32",
                               args=[("DPL", 0x00), ("DPH", 0x00), ("B", 0x00), ("ACC", 0x80),
                                     ("PARM_2", 0xFF), ("PARM_3", 0xFF), ("PARM_4", 0xFF), ("PARM_5", 0xFF)],
                               want32=0x55555555, opt="ReleaseSafe", sentinel=0x55,
                               expect_mem={0x8100: 0x5A}, steps=20000),
    "safe_imul32_ov": dict(kind="call", src="safemul32i.zig", fn="safe_imul32",
                           args=[("DPL", 0x00), ("DPH", 0x00), ("B", 0x01), ("ACC", 0x00),
                                 ("PARM_2", 0x00), ("PARM_3", 0x00), ("PARM_4", 0x01), ("PARM_5", 0x00)],
                           want32=0x55555555, opt="ReleaseSafe", sentinel=0x55,
                           expect_mem={0x8100: 0x5A}, steps=20000),
    "safe_imul32_big": dict(kind="call", src="safemul32i.zig", fn="safe_imul32",
                            args=[("DPL", 0x04), ("DPH", 0xB5), ("B", 0x00), ("ACC", 0x00),
                                  ("PARM_2", 0x04), ("PARM_3", 0xB5), ("PARM_4", 0x00), ("PARM_5", 0x00)],
                            want32=2147395600, opt="ReleaseSafe", steps=20000),
    # i16：-200*100；-32768*1 合法；-32768*-1 = 32768 溢出。
    "safe_imul16_ok": dict(kind="call", src="safemul16i.zig", fn="safe_imul16",
                           args=[("DPL", 0x38), ("DPH", 0xFF), ("PARM_2", 0x64), ("PARM_3", 0x00)],
                           want16=0xB1E0, opt="ReleaseSafe", steps=4000),
    "safe_imul16_min": dict(kind="call", src="safemul16i.zig", fn="safe_imul16",
                            args=[("DPL", 0x00), ("DPH", 0x80), ("PARM_2", 0x01), ("PARM_3", 0x00)],
                            want16=0x8000, opt="ReleaseSafe", steps=4000),
    "safe_imul16_ov": dict(kind="call", src="safemul16i.zig", fn="safe_imul16",
                           args=[("DPL", 0x00), ("DPH", 0x80), ("PARM_2", 0xFF), ("PARM_3", 0xFF)],
                           want16=0x5555, opt="ReleaseSafe", sentinel=0x55,
                           expect_mem={0x8100: 0x5A}, steps=4000),
    # i8：-16*8 = -128 合法；16*8 与 -16*-8 都是 +128，溢出。
    "safe_imul8_ok": dict(kind="call", src="safemul8i.zig", fn="safe_imul8",
                          args=[("DPL", 0xF0), ("PARM2", 0x08)], want=0x80, opt="ReleaseSafe"),
    "safe_imul8_max": dict(kind="call", src="safemul8i.zig", fn="safe_imul8",
                           args=[("DPL", 0x7F), ("PARM2", 0x01)], want=0x7F, opt="ReleaseSafe"),
    "safe_imul8_ov": dict(kind="call", src="safemul8i.zig", fn="safe_imul8",
                          args=[("DPL", 0x10), ("PARM2", 0x08)], want=0x55, opt="ReleaseSafe",
                          sentinel=0x55, expect_mem={0x8100: 0x5A}),
    "safe_imul8_ov2": dict(kind="call", src="safemul8i.zig", fn="safe_imul8",
                           args=[("DPL", 0xF0), ("PARM2", 0xF8)], want=0x55, opt="ReleaseSafe",
                           sentinel=0x55, expect_mem={0x8100: 0x5A}),
    # 边界检查覆盖度：不只单字节数组，宽元素、多维、切片都要判，且判据要用
    # 各自的长度（切片 1..3 是长度 2，不能拿原数组的 4 来判）。
    "bnd_u16_ok": dict(kind="call", src="bounds.zig", fn="bnd_u16",
                       args=[("DPL", 0x01)], want16=200, opt="ReleaseSafe"),
    "bnd_u16_ov": dict(kind="call", src="bounds.zig", fn="bnd_u16",
                       args=[("DPL", 0x04)], want16=0x5555, opt="ReleaseSafe",
                       sentinel=0x55, expect_mem={0x8100: 0xA5}),
    "bnd_u32_ok": dict(kind="call", src="bounds.zig", fn="bnd_u32",
                       args=[("DPL", 0x02)], want32=3, opt="ReleaseSafe"),
    "bnd_grid_ok": dict(kind="call", src="bounds.zig", fn="bnd_grid",
                        args=[("DPL", 0x01), ("PARM2", 0x02)], want=6, opt="ReleaseSafe"),
    "bnd_grid_ov_row": dict(kind="call", src="bounds.zig", fn="bnd_grid",
                            args=[("DPL", 0x02), ("PARM2", 0x00)], want=0x55, opt="ReleaseSafe",
                            sentinel=0x55, expect_mem={0x8100: 0xA5}),
    "bnd_grid_ov_col": dict(kind="call", src="bounds.zig", fn="bnd_grid",
                            args=[("DPL", 0x00), ("PARM2", 0x03)], want=0x55, opt="ReleaseSafe",
                            sentinel=0x55, expect_mem={0x8100: 0xA5}),
    "bnd_slice_ok": dict(kind="call", src="bounds.zig", fn="bnd_slice",
                         args=[("DPL", 0x01)], want=3, opt="ReleaseSafe"),
    "bnd_slice_ov": dict(kind="call", src="bounds.zig", fn="bnd_slice",
                         args=[("DPL", 0x02)], want=0x55, opt="ReleaseSafe",
                         sentinel=0x55, expect_mem={0x8100: 0xA5}),
    # 有符号走 OV 判据（PSW.2），不是进位判据。
    "safe_sadd_ok": dict(kind="call", src="safe.zig", fn="safe_sadd", args=[("DPL", 10), ("PARM2", 20)], want=30, opt="ReleaseSafe"),
    "safe_sadd_ov": dict(kind="call", src="safe.zig", fn="safe_sadd", args=[("DPL", 100), ("PARM2", 100)], want=0x55, opt="ReleaseSafe", sentinel=0x55, expect_mem={0x8100: 0x5A}),
    # 数组越界走 trap，诊断标记 0xA5 与溢出的 0x5A 区分。
    "safe_bounds_ok": dict(kind="call", src="safe.zig", fn="safe_bounds", args=[("DPL", 2)], want=3, opt="ReleaseSafe"),
    "safe_bounds_ov": dict(kind="call", src="safe.zig", fn="safe_bounds", args=[("DPL", 9)], want=0x55, opt="ReleaseSafe", sentinel=0x55, expect_mem={0x8100: 0xA5}),
    # 除零：安全档必须进 _mcs_panic（标记 0x3C），尺寸档一点代码都不加。
    "safe_div8":  dict(kind="call", src="safe.zig", fn="safe_div8",
                       args=[("DPL", 12), ("PARM2", 3)], want=4, opt="ReleaseSafe"),
    "safe_div8z": dict(kind="call", src="safe.zig", fn="safe_div8",
                       args=[("DPL", 12), ("PARM2", 0)], want=0x55, opt="ReleaseSafe",
                       sentinel=0x55, expect_mem={0x8100: 0xA5}),
    "safe_div32z": dict(kind="call", src="safe.zig", fn="safe_div32",
                        args=[("DPL", 0x78), ("DPH", 0x56), ("B", 0x34), ("ACC", 0x12),
                              ("PARM_2", 0), ("PARM_3", 0), ("PARM_4", 0), ("PARM_5", 0)],
                        want32=0x55555555, opt="ReleaseSafe",
                        sentinel=0x55, expect_mem={0x8100: 0x3C}, steps=6000),
    "safe_rem32z": dict(kind="call", src="safe.zig", fn="safe_rem32",
                        args=[("DPL", 0x78), ("DPH", 0x56), ("B", 0x34), ("ACC", 0x12),
                              ("PARM_2", 0), ("PARM_3", 0), ("PARM_4", 0), ("PARM_5", 0)],
                        want32=0x55555555, opt="ReleaseSafe",
                        sentinel=0x55, expect_mem={0x8100: 0x3C}, steps=6000),
    # 非尾递归必须编译期拒绝（静态参数区不可重入）。
    # want_code2 是 M1 的 AIR 还原门禁：建议里的表达式必须来自真实 AIR，
    # 而不是只剩占位符。降级成骨架时这条会立刻变红。
    "safe_rec_reject": dict(kind="reject", src="rec.zig", opt="ReleaseSafe",
                            want_err="非尾递归不受支持", want_code="rec_bad__tail(n, 0)",
                            want_code2="rec_bad((n - 1)) + 1"),
    # 改写建议：错误信息里必须出现可直接粘贴的 Zig 代码，而不只是中文说明。
    "diag_mul_reject": dict(kind="reject", src="diag_mul.zig", opt="ReleaseSafe", want_err="≤32 位整数"),
    "diag_addr": dict(kind="call", src="diag_addr.zig", fn="diag_addr", args=[], want16=3, steps=2000),
    "diag_switch_reject": dict(kind="reject", src="diag_switch.zig", opt="ReleaseSafe", want_err="switch 的判定值", want_code="handlers[op](arg)"),
    "diag_dim": dict(kind="call", src="diag_dim.zig", fn="diag_dim",
                    args=[("DPL", 1), ("PARM2", 0)], want=3, steps=2000),
    # 重复复杂算法压缩：三个同构乘法必须压成一份共享子程序，且结果不变。
    # want_shared 是「压缩确实发生」的门禁，防止优化悄悄退化成全内联。
    "factor_a": dict(kind="call", src="factor.zig", fn="fac_a",
                     args=[("DPL", 0x34), ("DPH", 0x12), ("PARM2", 0x20), ("PARM_3", 0x00)],
                     want16=0x4680, want_shared=3, no_site_shift=True),
    "factor_b": dict(kind="call", src="factor.zig", fn="fac_b",
                     args=[("DPL", 0x12), ("DPH", 0x00), ("PARM2", 0x03), ("PARM_3", 0x00)],
                     want16=0x0036, want_shared=3, no_site_shift=True),
    "factor_c": dict(kind="call", src="factor.zig", fn="fac_c",
                     args=[("DPL", 0xFF), ("DPH", 0xFF), ("PARM2", 0x02), ("PARM_3", 0x00)],
                     want16=0xFFFE, want_shared=3, no_site_shift=True),
    # 反例：单条加减/位运算被 lcall+ret 取代必然更大，两个同构函数也不许压缩。
    "factor_cheap": dict(kind="call", src="cheap.zig", fn="cheap_a",
                         args=[("DPL", 3), ("PARM2", 4)], want=0x5D, forbid_shared=True),
}

ORDER = ["selftest", "add", "varfn", "addrfn", "sum", "cnt", "sum_to_fold", "big",
         "interrupt", "memrt", "bitfn", "xor2", "ne5", "ne_imm", "bitpoll", "bitclear",
         "shl2", "shr3", "setbit", "clrbit",
         "mul8", "div8", "rem8", "not8", "xnor8",
         "u16add", "u16sub", "u16carry", "u16shl", "u16shr", "u32add", "u32carry",
         "sexcmp", "sexcmp2", "sex16", "i32add", "sar32", "sar8",
         "shr32t", "shl32t", "shl32c",
         "ucmp_eq", "ucmp_gt", "ucmp_lt", "wbits",
         "u16mul", "u16mul2", "i16mul", "u32mul",
         "u16div", "u16rem", "u32div", "u32rem", "i32div", "i32rem", "i8div", "i8rem", "i16div",
         "shlv", "shrv", "shrv0", "sarv",
         "lt32", "lt32b", "ge8t", "ge8f",
         "chain", "chain32", "mix32",
         "call_ind", "twice_ind", "call_addr", "dispatch",
         "wstore", "wround", "wround2", "addone",
         "t16rt", "t8rt", "t16pair", "t8pair", "t32rt", "t32pair", "bscale", "wg32", "wg16", "wginc", "wgcmp1", "wgcmp0", "trsum", "trev", "trod",
         "pprt", "pu16", "fb3d", "fbchk", "gfb", "p2d",
         "symconst", "symrt", "symb", "sympair", "fpt_all",
         "daddr0", "daddr1", "daddr2", "daddr3",
         "argcall1", "argcall2", "argcall3", "cget2", "cgeti", "wgeti",
         "g2", "g2c", "g2r",
         "sw1h", "sw1m", "sw2r", "sw2h", "sw2e", "sw3a", "sw3b",
         "ifx1", "ifx0", "ifr1", "ifr0", "swx2", "swx9", "ifw1", "ifw0",
         "wloc1", "wloc2", "s16r", "u16l", "u32l",
         "csin90", "csin45", "csin180", "ccos0", "cat90", "cat45",
         "csqrt1m", "chyp", "ringdemo",
         "safe_add_ok", "safe_add_ov", "safe_sub_ok", "safe_sub_ov",
         "safe_mul_ok", "safe_mul_ov", "safe_sadd_ok", "safe_sadd_ov",
         "safe_bounds_ok", "safe_bounds_ov", "safe_rec_reject",
         "safe_div8", "safe_div8z", "safe_div32z", "safe_rem32z",
         "safe_mul16_ok", "safe_mul16_ov",
         "safe_mul32_max", "safe_mul32_ok", "safe_mul32_ov",
         "safe_mul32_one", "safe_mul32_big",
         "safe_imul32_ok", "safe_imul32_min", "safe_imul32_ov_min", "safe_imul32_ov",
         "safe_imul32_big", "safe_imul16_ok", "safe_imul16_min", "safe_imul16_ov",
         "safe_imul8_ok", "safe_imul8_max", "safe_imul8_ov", "safe_imul8_ov2",
         "bnd_u16_ok", "bnd_u16_ov", "bnd_u32_ok", "bnd_grid_ok",
         "bnd_grid_ov_row", "bnd_grid_ov_col", "bnd_slice_ok", "bnd_slice_ov",
         "diag_mul_reject", "diag_addr", "diag_switch_reject", "diag_dim",
         "factor_a", "factor_b", "factor_c", "factor_cheap", "sar32v"]


def check_selftest() -> bool:
    """MIR 发射器自检：跑 selftest.zig（汇编走 stderr），4 个 xram 点全对。"""
    zig = shutil.which("zig")
    if not zig:
        raise SystemExit("找不到系统 zig")
    selftest = SRC_TREE / "src" / "codegen" / "mcs2" / "selftest.zig"
    # 冷缓存时 `zig run` 首次可能只输出编译过程、拿不到汇编（实测全量首跑偶发
    # FAIL: selftest，单项与第二次全量都通过）。给一次重试，仍拿不到才判失败。
    asm = ""
    for attempt in range(2):
        r = run([zig, "run", str(selftest)], cwd=HERE, env=build_env(), check=False)
        asm = (r.stderr or "") + (r.stdout or "")
        if r.returncode == 0 and ".area CSEG (CODE)" in asm:
            break
        if attempt == 0:
            print("  RETRY: selftest 首次未拿到汇编（冷缓存），重跑一次")
    else:
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
    _, text = emit_asm(TESTS / spec["src"], name, opt=spec.get("opt", "ReleaseSmall"))
    if spec.get("want_ljmp") and "ljmp" not in text:
        print("FAIL: 期望长跳（ljmp）但产物里没有——跳转松弛没生效")
        return False
    if spec.get("want_shared"):
        n = text.count("lcall _mcs_sh_")
        if n < spec["want_shared"]:
            print(f"FAIL: 期望至少 {spec['want_shared']} 处共享算法调用，实际 {n} 处")
            return False
        print(f"  PASS: {name} 共享算法调用 {n} 处")
    if spec.get("forbid_shared"):
        if "lcall _mcs_sh_" in text:
            print("FAIL: 加减/位运算这类廉价序列不应生成共享子程序")
            return False
        print(f"  PASS: {name} 廉价运算保持内联（无共享调用）")
    if spec.get("want_rt"):
        # rtlib 门禁：模板调用次数够，且**模板文本只出现一次**——符号是汇编
        # 单元局部的，重复定义会让链接直接失败；而调用退化成内联则白丢体积。
        n = text.count("lcall _mcs_rt_")
        if n < spec["want_rt"]:
            print(f"FAIL: 期望至少 {spec['want_rt']} 处 rtlib 模板调用，实际 {n} 处")
            return False
        sym = spec.get("rt_sym") or "_mcs_rt_sar32"
        if text.count("\n" + sym + ":") != 1:
            print("FAIL: rtlib 模板文本应恰好出现一次（符号单元局部，重复定义会链接失败）")
            return False
        print(f"  PASS: {name} rtlib 模板调用 {n} 处，模板本体 1 份")
    if spec.get("want_no_rt"):
        if "lcall _mcs_rt_" in text:
            print("FAIL: 运行期移位次数不应套固定模板（djnz 先减后判，0 会转 256 次）")
            return False
        print(f"  PASS: {name} 运行期次数保持内联")
    if spec.get("no_site_shift"):
        # 站点槽重绑定门禁：非拥有者站点必须把输入直接写进拥有者槽，
        # 产物里不应再出现「vreg → vreg」的 `mov _mcs_vX,_mcs_vY` 搬运。
        # 一旦重绑失效（比如块专用临时量的判定被改坏），这条会立刻变红。
        hit = re.search(r"mov\s+_mcs_v\d+,_mcs_v\d+", text)
        if hit:
            print(f"FAIL: 站点仍在搬运共享槽（{hit.group(0)}）——重绑没生效")
            return False
        print(f"  PASS: {name} 站点零搬运（重绑生效）")
    want_wide = spec.get("want16") if spec.get("want16") is not None else spec.get("want32")
    ret_bytes = spec.get("ret_bytes", 1)
    if spec.get("want16") is not None:
        ret_bytes = 2
    if spec.get("want32") is not None:
        ret_bytes = 4
    merged = merge(name, driver_call(spec["fn"], spec["args"], ret_bytes=ret_bytes,
                                     sentinel=spec.get("sentinel")), text)
    ihx = assemble(merged, name, dseg=dseg)
    # 注意：expect_mem 与 want_wide 要**合并**，不能互相覆盖。以前是
    # `expect_mem = {0x8000+i: ...}` 直接覆盖，导致所有宽返回值用例的
    # 「停机标记 0x8100 = 0x5A/0xA5」从来没被真正检查过——哨兵没被改写只能
    # 说明函数停过，分不清是溢出停机还是别的原因没写结果。
    expect_mem: dict[int, int] = dict(spec.get("expect_mem") or {})
    if want_wide is not None:
        for i in range(ret_bytes):
            expect_mem[0x8000 + i] = (want_wide >> (8 * i)) & 0xFF
    # dump 区间要按地址连续性切段：额外的停机标记（0x8100）和返回值（0x8000）
    # 不相邻，塞进一个区间会把中间几千字节全 dump 出来。
    extra = None
    if expect_mem:
        addrs = sorted(expect_mem)
        extra = []
        start = prev = addrs[0]
        for a in addrs[1:] + [None]:
            if a is not None and a == prev + 1:
                prev = a
                continue
            extra.append((start, prev - start + 1))
            if a is not None:
                start = prev = a
    got = sim(ihx, steps=steps, slots=1, extra=extra)
    ok = True
    if want_wide is None and spec.get("want") is not None:
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
    _, text = emit_asm(TESTS / "interrupt.zig", name)
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


def check_interop() -> bool:
    """C(SDCC) ↔ Zig(mcs2) 混链门禁。

    边界 ABI 与 SDCC `--model-small` 逐字节对齐是「C 互操作」的底线；
    只改后端不改 ABI 也必须保证这条链不散。脚本同时核对 C 侧参数摆放
    与 Zig 侧导出符号，用 SDCC 当链接器生成 .ihx。
    """
    script = HERE / "interop" / "build.py"
    if not script.exists():
        print("  SKIP: 没有混链脚本")
        return True
    r = subprocess.run([sys.executable, str(script)], capture_output=True,
                       text=True, encoding="utf-8", errors="replace")
    output = (r.stdout or "") + (r.stderr or "")
    ok = r.returncode == 0 and "OK:" in output
    if not ok:
        print(output[-1200:])
    print(f"  {'PASS' if ok else 'FAIL'}: C↔Zig 混链（SDCC 链接器）")
    return ok


def check_reject(name: str, spec: dict) -> bool:
    """期望编译失败的用例：必须给出明确中文错误，而不是静默生成错误代码。"""
    src = TESTS / spec["src"]
    out = BUILD / f"{name}.asm"
    r = subprocess.run(
        [str(ZIG_EXE), "build-obj", f"-O{spec.get('opt', 'ReleaseSmall')}",
         "-target", TARGET, "--dep", "cordic", f"-Mroot={src}",
         f"-Mcordic={CORDIC}", "-femit-bin=" + str(out)],
        env=zig_env(), capture_output=True, text=True, encoding="utf-8", errors="replace")
    output = (r.stdout or "") + (r.stderr or "")
    err_ok = r.returncode != 0 and spec["want_err"] in output
    code_ok = spec.get("want_code") is None or spec["want_code"] in output
    code2_ok = spec.get("want_code2") is None or spec["want_code2"] in output
    ok = err_ok and code_ok and code2_ok
    if not ok:
        print(output[-800:])
    print(f"  {'PASS' if ok else 'FAIL'}: {name} 编译期拒绝（含「{spec['want_err']}」）")
    if spec.get("want_code"):
        print(f"  {'PASS' if code_ok else 'FAIL'}: 改写建议含代码「{spec['want_code']}」")
    if spec.get("want_code2"):
        print(f"  {'PASS' if code2_ok else 'FAIL'}: 建议里还原出的真实表达式「{spec['want_code2']}」")
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
        elif name in CASES and CASES[name]["kind"] == "reject":
            ok = check_reject(name, CASES[name])
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
    # 只在全量验收跑混链：单项调试不必每次都重编 C 侧。
    if not names and not failed:
        print("== C 互操作门禁")
        if not check_interop():
            failed.append("interop")
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
    # 「像真程序」的固件：函数指针表分派 + u16 运算 + UART 打印（AI8051U，115200）
    "realapp": dict(src="realapp.zig", name="realapp_ai8051u", dseg=0x30, cseg=0x0000),
}


def firmware(which: str, tag: str = "") -> int:
    need_compiler()
    spec = FW.get(which)
    if not spec:
        print(f"未知固件 {which}；可用：{', '.join(FW)}")
        return 2
    BUILD.mkdir(parents=True, exist_ok=True)
    _, text = emit_asm(TESTS / spec["src"], spec["name"])
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
