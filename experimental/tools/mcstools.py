#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mcstools.py — 构建层 Python 工具的单一入口（供 PyInstaller 冻结为 mcstools.exe）。

把这些只依赖标准库的后处理工具合并成一个可执行文件，目标机**无需安装 Python**即可完成
构建层后处理（便携工具链集用）。

用法（源码 / exe 一致）：
    mcstools fix     <asm>   # 等价 tools/fix_mcs_labels.py —— 修局部标签重名
    mcstools opt     <asm>   # 等价 tools/mcs_opt.py         —— 局部汇编瘦身
    mcstools ir      <asm>   # 等价 tools/mcs_ir.py          —— IR 提示消费 + 死 store 消除
    mcstools overlay <asm>   # 等价 tools/mcs_overlay.py     —— MCS-51 帧叠加（mcs251 空操作）
    mcstools dce     ...     # 等价 tools/mcs_dce.py         —— 跨模块死代码回收

    mcstools --version       # 打印各工具自述（用于便携集自检）
"""

from __future__ import annotations

import sys

# 目标机 / CI 的控制台默认编码可能是 cp1252 等非 UTF-8，打印中文会抛 UnicodeEncodeError。
# 统一把标准输出/错误重设为 UTF-8（无法重设时忽略）。
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

import fix_mcs_labels
import mcs_ir
import mcs_dce
import mcs_opt
import mcs_overlay

_TOOLS = {
    "fix": fix_mcs_labels,
    "opt": mcs_opt,
    "ir": mcs_ir,
    "overlay": mcs_overlay,
    "dce": mcs_dce,
}

_USAGE = "usage: mcstools <fix|opt|ir|overlay|dce> [args...]"


def main() -> int:
    argv = sys.argv[1:]
    if not argv or argv[0] in ("-h", "--help"):
        sys.stderr.write(_USAGE + "\n")
        return 0 if argv else 2
    if argv[0] in ("-V", "--version"):
        sys.stdout.write("mcstools: " + ", ".join(sorted(_TOOLS)) + "\n")
        return 0
    name = argv[0]
    mod = _TOOLS.get(name)
    if mod is None:
        sys.stderr.write(f"mcstools: unknown tool '{name}'\n{_USAGE}\n")
        return 2
    rest = argv[1:]
    # 各工具入口签名不一致：mcs_ir.main(argv) 自己去掉 argv[0]，其余 main(argv=None) 交给 argparse。
    sys.argv = [name] + rest
    try:
        rc = mod.main(sys.argv) if name == "ir" else mod.main()
    except SystemExit as e:  # argparse 的 --help / 参数错误
        return int(e.code) if e.code else 0
    return int(rc) if rc else 0


if __name__ == "__main__":
    raise SystemExit(main())
