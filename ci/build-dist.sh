#!/usr/bin/env bash
# 在 Linux / macOS 上构建并打包发布件（不用 GitHub Actions）。
#
#   ZIG=/path/to/zig-0.17.x ./ci/build-dist.sh
#
# 要求：引导 zig 的版本必须 >= 本树（0.17.1-dev）。0.17.1 尚未正式发版，
# 用 ziglang.org 的 master 或自编译的 0.17.1。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD

ZIG=${ZIG:-zig}
echo "== 引导 zig: $($ZIG version)"

# 1) 构建编译器（ReleaseFast）。ZIG_LIB_DIR 必须指向本树 lib。
export ZIG_LIB_DIR=$ROOT/lib
export ZIG_GLOBAL_CACHE_DIR=$ROOT/.zig-global-cache
"$ZIG" build -Doptimize=ReleaseFast -Dno-lib --summary all

# 2) 打包（编译器 + lib 子集 + 示例 + 工具）
python3 tools/mcs2/dist.py

echo "== 产物："
ls -lh dist/*.zip