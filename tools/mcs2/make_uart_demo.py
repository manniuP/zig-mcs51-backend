#!/usr/bin/env python3
"""生成 UART 实机固件（build/fw/uart_demo_8h8k64u.ihx）。

兼容入口：实际实现在 mcs2.py fw。
"""
import sys
from mcs2 import main

sys.exit(main(["fw", "uart"]))
