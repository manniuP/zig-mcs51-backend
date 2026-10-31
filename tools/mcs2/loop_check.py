#!/usr/bin/env python3
"""M2 验收：sum / cnt / sum_to_fold（PE 折叠）。

兼容入口：实际实现在 mcs2.py（工具发现 / 环境 / 布局 / 驱动桩 / ucsim 解析都在那里）。
"""
import sys
from mcs2 import main

sys.exit(main(["check", "sum", "cnt", "sum_to_fold"]))
