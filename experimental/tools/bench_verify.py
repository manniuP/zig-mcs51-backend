#!/usr/bin/env python3
"""bench_verify.py —— 真机读 `zigbench`（examples/ai8051u_zig_bench）周期输出并核对。

zigbench 的 UART1（P3.1）@9600 持续输出：
    bench
    nop=XXXX
    rd d=XXXX i=XXXX e=XXXX x=XXXX
    exe o0=XXXX o5=XXXX
本脚本从串口抓一帧，解析 16 位十六进制周期数，做基本断言：
    - 四个读延迟、两个执行周期都应为非零（为 0/缺行多为测量回绕或没烧对固件）；
    - 打印相对趋势（data 直址应最快，idata/edata/xdata 依次或不低于 data）。
真机验证步骤见 examples/ai8051u_zig_bench/README.md。

用法：
  python tools/bench_verify.py                 # 默认 COM8 @9600
  python tools/bench_verify.py --port COM8 --baud 9600 --timeout 8
"""
import argparse
import re
import sys
import time

try:
    import serial
except ImportError:
    print("需要 pyserial：python -m pip install pyserial")
    sys.exit(2)

FIELDS = ("d", "i", "e", "x")


def parse(buf):
    """从累积文本里解析一帧；返回 dict 或 None。"""
    nop = re.search(r"nop=([0-9a-fA-F]{1,4})", buf)
    rd = re.search(r"rd d=([0-9a-fA-F]{1,4}) i=([0-9a-fA-F]{1,4}) "
                   r"e=([0-9a-fA-F]{1,4}) x=([0-9a-fA-F]{1,4})", buf)
    exe = re.search(r"exe o0=([0-9a-fA-F]{1,4}) o5=([0-9a-fA-F]{1,4})", buf)
    if not (nop and rd and exe):
        return None
    return {
        "nop": int(nop.group(1), 16),
        "rd": {k: int(v, 16) for k, v in zip(FIELDS, rd.groups())},
        "exe": {"o0": int(exe.group(1), 16), "o5": int(exe.group(2), 16)},
    }


def read_frame(port, baud, timeout):
    with serial.Serial(port, baud, timeout=0.5) as s:
        s.reset_input_buffer()
        buf = ""
        deadline = time.time() + timeout
        while time.time() < deadline:
            chunk = s.read(256)
            if chunk:
                buf += chunk.decode("ascii", "replace")
                frame = parse(buf)
                if frame:
                    return frame
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="COM8")
    ap.add_argument("--baud", type=int, default=9600)
    ap.add_argument("--timeout", type=float, default=8.0)
    args = ap.parse_args()

    frame = read_frame(args.port, args.baud, args.timeout)
    if not frame:
        print("[bench] FAIL：%s@%d 未抓到完整帧（没烧对固件 / 占用 / 波特率不符）"
              % (args.port, args.baud))
        return 1

    rd, exe = frame["rd"], frame["exe"]
    print("[bench] %s@%d" % (args.port, args.baud))
    print("        nop=0x%04x" % frame["nop"])
    print("        rd  d=0x%04x i=0x%04x e=0x%04x x=0x%04x"
          % (rd["d"], rd["i"], rd["e"], rd["x"]))
    print("        exe o0=0x%04x o5=0x%04x" % (exe["o0"], exe["o5"]))

    bad = [k for k, v in list(rd.items()) + list(exe.items()) if v == 0]
    if bad:
        print("[bench] FAIL：以下测量为 0（疑似回绕/固件不符）：%s"
              % ", ".join(bad))
        return 1

    # 趋势（提示性，不作为硬失败）：data 直址应最快，其余不低于它。
    if not (rd["i"] >= rd["d"] and rd["e"] >= rd["d"] and rd["x"] >= rd["d"]):
        print("[bench] 提示：读延迟趋势异常（预期 d <= i/e/x），请核对放置标签。")
    print("[bench] OK：六项周期均非零，可用于对比。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
