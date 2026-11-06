"""rtlib 模板的边界值仿真检查（ucsim）。

`mcs2.py check` 里每个用例只测一个值，对 rtlib 这种「整块语义靠手写汇编」
的模板不够——算术右移的符号位、跨字节进位、次数 31 这些点一旦写错，
单个用例很容易漏过。本脚本用**真实编译产物**跑值域扫描。

用法：
    python rtcheck.py            # 默认跑 sar32 全部边界值
    python rtcheck.py sar32      # 指定模板

与 mcs2.py check 的分工：那边是每次提交必跑的门禁（1 个值），这边是
改动模板后手工跑的值域扫描（多值，慢）。
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import mcs2

# 每个模板一组 (输入, 次数) —— 值选在容易错的地方：
# 符号位刚置位、全 1、末尾全 0、跨字节边界、次数极值。
SAR32_CASES = [
    (0x12345678, 3),    # 常规正数
    (0xFFFFFFFF, 3),    # 全 1，负数
    (0xFFFFFFF0, 3),    # 验收里唯一测的那个
    (0x80000000, 1),    # 符号位刚置位：错成逻辑右移会得 0x40000000
    (0x7FFFFFFF, 1),    # 符号位为 0 的最大正数
    (0xCAFEBABE, 11),   # 次数跨字节
    (0x00000000, 5),    # 零
    (0x80000001, 31),   # 次数上限 + 负数
    (0xFFFFFFFF, 31),   # 次数上限 + 全 1
    (0x0000FFFF, 15),   # 低位全 1，移出到只剩 1
]


def src_for(cnt: int) -> Path:
    p = mcs2.BUILD / ("rtchk_sar32_%d.zig" % cnt)
    p.write_text("export fn f(x: i32) i32 { return x >> %d; }\n" % cnt,
                 encoding="utf-8")
    return p


def run_sar32(v: int, cnt: int) -> int:
    src = src_for(cnt)
    _, text = mcs2.emit_asm(src, "rtchk_%d" % cnt)
    if "lcall _mcs_rt_sar32" not in text:
        raise SystemExit("模板没被套用——检查 rtlib 识别条件")
    drv = mcs2.driver_call("f", [
        ("DPL", v & 0xFF), ("DPH", (v >> 8) & 0xFF),
        ("B", (v >> 16) & 0xFF), ("ACC", (v >> 24) & 0xFF)], ret_bytes=4)
    tag = "rtchk_%d_%08x" % (cnt, v)
    merged = mcs2.merge(tag, drv, text)
    ihx = mcs2.assemble(merged, tag, dseg=0x30)
    g = mcs2.sim(ihx, 4000, 4)
    return g[0x8000] | (g[0x8001] << 8) | (g[0x8002] << 16) | (g[0x8003] << 24)


def report(name: str, cases, run) -> bool:
    bad = 0
    for v, c in cases:
        exp = (v - (1 << 32) if v & 0x80000000 else v) >> c
        exp &= 0xFFFFFFFF
        got = run(v, c)
        ok = got == exp
        if not ok:
            bad += 1
        print("  %08X >> %2d = %08X  期望 %08X  %s" %
              (v, c, got, exp, "OK" if ok else "**错**"))
    total = len(cases)
    print("\n%s：%d/%d 通过" % (name, total - bad, total))
    return bad == 0


def main() -> int:
    which = sys.argv[1] if len(sys.argv) > 1 else "sar32"
    if which == "sar32":
        return 0 if report("sar32", SAR32_CASES, run_sar32) else 1
    raise SystemExit("未知模板 %s（当前只有 sar32）" % which)


if __name__ == "__main__":
    sys.exit(main())
