#!/usr/bin/env python3
"""打包发布件：编译器 + lib 子集 + 示例 + 工具（+ Windows 附 SDCC）。

用法：python tools/mcs2/dist.py [--no-sdcc]

设计说明：不做交叉编译。要 Linux/macOS 版本请**在对应平台**上跑本脚本——
本树是 0.17.1-dev，必须用匹配版本的引导 zig；跨目标构建还受 build.zig 的
configure 步骤限制（当前会报 package "" configuration failed）。
"""
from __future__ import annotations

import argparse
import platform
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
WS = REPO.parent
VERSION = "0.17.1"

LIB_KEEP = ("std", "compiler", "compiler_rt", "c")
LIB_SKIP = ("libc", "libcxx", "libcxxabi", "libunwind", "libtsan", "docs", "include")


def run(cmd, **kw):
    print("+", " ".join(str(c) for c in cmd))
    subprocess.run(cmd, check=True, **kw)


def host_tag() -> str:
    sysname = platform.system().lower()
    osname = {"windows": "windows", "linux": "linux", "darwin": "macos"}.get(sysname, sysname)
    arch = platform.machine().lower()
    arch = {"amd64": "x86_64", "arm64": "aarch64"}.get(arch, arch)
    return f"{osname}-{arch}"


def find_compiler() -> Path:
    for cand in (WS / "zig017" / "mcs2build" / "zig-out" / "bin" / "zig.exe",
                 WS / "zig017" / "mcs2build" / "zig-out" / "bin" / "zig"):
        if cand.exists():
            return cand
    raise SystemExit("找不到编译器：先跑 python tools/mcs2/mcs2.py build")


def copy_lib(dst: Path) -> None:
    src = REPO / "lib"
    out = dst / "lib"
    out.mkdir(parents=True, exist_ok=True)
    for f in src.iterdir():
        if f.name in LIB_SKIP:
            continue
        if f.is_dir():
            shutil.copytree(f, out / f.name)
        else:
            shutil.copy2(f, out / f.name)


def copy_examples(dst: Path) -> None:
    ex = dst / "examples"
    ex.mkdir(parents=True, exist_ok=True)
    src = REPO / "examples" / "mcs51"
    (ex / "mcs51").mkdir(exist_ok=True)
    for name in ("src", "lib"):
        shutil.copytree(src / name, ex / "mcs51" / name)
    for name in ("build.zig", "cases.txt", "README.md"):
        if (src / name).exists():
            shutil.copy2(src / name, ex / "mcs51" / name)
    cmp_src = REPO / "examples" / "compare"
    if cmp_src.exists():
        shutil.copytree(cmp_src, ex / "compare",
                        ignore=shutil.ignore_patterns("out", "*.lst", "*.obj", "*.OBJ", "*.LST"))


def copy_tools(dst: Path) -> None:
    out = dst / "tools" / "mcs2"
    out.mkdir(parents=True, exist_ok=True)
    for f in (REPO / "tools" / "mcs2").glob("*.py"):
        if f.name.startswith("_"):
            continue
        shutil.copy2(f, out / f.name)


def zip_dir(src: Path, out_zip: Path) -> None:
    with zipfile.ZipFile(out_zip, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for p in sorted(src.rglob("*")):
            if p.is_file():
                z.write(p, p.relative_to(src.parent))
    print(f"→ {out_zip}  {out_zip.stat().st_size // (1024 * 1024)} MB")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-sdcc", action="store_true", help="不附带 Windows SDCC 工具链")
    args = ap.parse_args()

    comp = find_compiler()
    tag = host_tag()
    name = f"zig-mcs51-{VERSION}-{tag}"
    dist = REPO / "dist"
    pkg = dist / name
    if pkg.exists():
        shutil.rmtree(pkg)
    pkg.mkdir(parents=True)

    shutil.copy2(comp, pkg / comp.name)
    copy_lib(pkg)
    copy_examples(pkg)
    copy_tools(pkg)
    for f in ("README.md", "LICENSE"):
        if (REPO / f).exists():
            shutil.copy2(REPO / f, pkg / f)

    sdcc = WS / "mcs251" / "tools" / "sdcc-mcs251-windows-x64"
    if not args.no_sdcc and platform.system().lower() == "windows" and sdcc.exists():
        inner = sdcc / "sdcc-mcs251" if (sdcc / "sdcc-mcs251").exists() else sdcc
        shutil.copytree(inner, pkg / "sdcc")

    zip_dir(pkg, dist / f"{name}.zip")
    print("完成：", pkg)
    return 0


if __name__ == "__main__":
    sys.exit(main())