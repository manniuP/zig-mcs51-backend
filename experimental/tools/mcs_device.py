#!/usr/bin/env python3
"""设备描述文件（devices/<vendor>/<part>.toml）的加载、校验与生成器。

用途：把「芯片契约」编译成工具链的输入——
  链接参数       : --emit sdcc-args
  sdld 命令文件  : --emit lk
  启动文件骨架   : --emit crt0
  摘要/校验      : --emit summary

约定：
  - 设备文件用 `[device].family` 指向同目录 families.toml 的 [families.<name>]，
    继承 core_profile / peripheral_group 等公共项。
  - 地址空间、机制寄存器、中断模型见 devices/README.md。
  - 只依赖 Python 标准库（tomllib）。Python >= 3.11。

示例：
  python tools/mcs_device.py devices/stc/ai8051u-34k64.toml --emit summary
  python tools/mcs_device.py devices/stc/stc8h8k64u.toml --emit sdcc-args
  python tools/mcs_device.py devices/stc/ai8051u-34k64.toml --emit lk
  python tools/mcs_device.py --self-test
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tomllib
from pathlib import Path

# ---------------------------------------------------------------------------
# 加载
# ---------------------------------------------------------------------------


class DeviceError(Exception):
    pass


def _read_toml(path: Path) -> dict:
    with path.open("rb") as f:
        return tomllib.load(f)


def load_device(path: Path) -> dict:
    """读取设备文件并合入 families.toml 的家族/内核默认。

    支持 `[device].template`：先加载同族模板，再用本文件的 `[override]`
    （flash/idata/edata/xdata/eeprom）与 `[device]` 字段覆盖。
    """
    doc = _read_toml(path)
    dev = dict(doc.get("device") or {})
    tpl = dev.get("template")
    if tpl:
        base = load_device((path.parent / tpl).resolve())
        ov = doc.get("override") or {}
        code = dict(base.get("code") or {})
        if ov.get("flash") is not None:
            code["size"] = int(ov["flash"])
        base["code"] = code
        flash = int(code.get("size", 0))
        for m in base.get("memory") or []:
            k = m.get("kind")
            if k in ov and ov[k] is not None and ov[k] != "IAP":
                m["size"] = int(ov[k])
        if ov.get("eeprom") is not None:
            for m in base.get("memory") or []:
                if m.get("kind") == "eeprom":
                    if ov["eeprom"] == "IAP":
                        m["size"] = flash
                        m["base"] = int(code.get("base", 0))
                        m["in_flash"] = True
                    else:
                        m["size"] = int(ov["eeprom"])
        dev2 = dict(base.get("device") or {})
        for k, v in dev.items():
            if k != "template":
                dev2[k] = v
        base["device"] = dev2
        for k, v in doc.items():
            if k not in ("device", "override"):
                base[k] = v
        doc, dev = base, dev2

    family = dev.get("family")
    fam_rec: dict = dict(doc.get("_family") or {})
    core_profile: dict = dict(doc.get("_core") or {})
    fam_path = path.parent / "families.toml"
    if not fam_path.is_file():
        fam_path = path.parent.parent / "families.toml"
    if family and fam_path.is_file():
        famdoc = _read_toml(fam_path)
        families = famdoc.get("families") or {}
        if family not in families:
            raise DeviceError(f"{path}: families.toml 无 [families.{family}]")
        fam_rec = dict(families[family])
        cp_name = fam_rec.get("core_profile")
        if cp_name:
            core_profile = dict((famdoc.get("core_profiles") or {}).get(cp_name) or {})
    result = dict(doc)
    result["device"] = dev
    result["_family"] = fam_rec
    result["_core"] = core_profile
    return result


def _header_for(family: str, model: str) -> str | None:
    """按 family + 型号前缀选厂商 Keil 头（相对 tools/vendor/stc/keil）。"""
    m = model.upper()
    if family == "ai8051":
        return "c251/AI8051U.H"
    if family == "ai32":
        return "c251/AI32G.H"
    if family == "stc32":
        return "c251/STC32G144K246.H" if "144K246" in m else "c251/STC32G.H"
    if family == "ai8":
        if m.startswith("AI8G"):
            return "c51/AI8G.H"
        if m.startswith("AI8A"):
            return "c51/AI8A8K64D4.H"
        if m.startswith("AI8C"):
            return "c51/AI8C.H"
        return "c51/AI8H.H"
    if family == "stc8":
        if m.startswith("STC8G"):
            return "c51/STC8G.H"
        if m.startswith("STC8A"):
            return "c51/STC8A8K64D4.H"
        if m.startswith("STC8C"):
            return "c51/STC8C.H"
        return "c51/STC8H.H"
    if family == "stc15":
        return "c51/STC15H.H" if m.startswith("STC15H") else "c51/STC15.H"
    if family == "stc12":
        if m.startswith("STC12H"):
            return "c51/STC12H.H"
        if "5A" in m:
            return "c51/STC12C5A60S2.H"
        if any(s in m for s in ("1052", "2052", "3052", "4052", "5052")):
            return "c51/STC12C2052AD.H"
        if any(s in m for s in ("5401", "5402", "5404", "5406", "5408", "5412")):
            return "c51/STC12C5410AD.H"
        if "56" in m:
            return "c51/STC12C5630AD.H"
        return "c51/STC12C5A60S2.H"
    if family == "classic89":
        return "c51/STC90C5xAD.H" if m.startswith("STC90") else "c51/STC89C5xRC.H"
    return None


def expand(matrix_path: Path, out_dir: Path) -> int:
    """按 model_matrix.toml 生成每型号设备 TOML（template + [override]）。"""
    doc = _read_toml(matrix_path)
    models = doc.get("model") or []
    out_dir.mkdir(parents=True, exist_ok=True)
    n = 0
    for row in models:
        model = row["model"]
        slug = re.sub(r"[^a-z0-9]+", "-", model.lower()).strip("-")
        tpl_abs = (matrix_path.parent / row["template"]).resolve()
        rel = os.path.relpath(tpl_abs, out_dir).replace("\\", "/")
        lines = [
            "# 由 tools/mcs_device.py --expand 生成，请勿手改。",
            f"# 源：model_matrix.toml（{row.get('source', '')}）",
            "",
            "[device]",
            f'id = "stc/{slug}"',
            f'family = "{row["family"]}"',
            f'model = "{model}"',
            f'template = "{rel}"',
            f'doc = "{row.get("source", "")}"',
        ]
        hdr = row.get("header") or _header_for(row["family"], model)
        if hdr:
            root = Path(__file__).resolve().parent.parent
            hdr_abs = (root / "tools/vendor/stc/keil" / hdr).resolve()
            lines.append(f'sfr_source = "{os.path.relpath(hdr_abs, out_dir).replace(chr(92), "/")}"')
        lines += ["", "[override]"]
        for k in ("flash", "idata", "edata", "xdata", "eeprom"):
            if k in row and row[k] is not None:
                v = row[k]
                lines.append(f'{k} = "{v}"' if isinstance(v, str) else f"{k} = {hex(int(v))}")
        lines.append("")
        out = out_dir / f"{slug}.toml"
        out.write_text("\n".join(lines), encoding="utf-8")
        problems = validate(load_device(out))
        if problems:
            print(f"FAIL {out.name}:")
            for x in problems:
                print("      " + x)
            return 1
        n += 1
    print(f"generated {n} device files -> {out_dir}")
    return 0


# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------


def _mem(doc: dict, kind: str) -> dict | None:
    for m in doc.get("memory") or []:
        if m.get("kind") == kind:
            return m
    return None


def _addr_width(doc: dict) -> int:
    return int((doc.get("code") or {}).get("addr_width", 16))


def _hex(v: int, width: int) -> str:
    width = max(2, (width + 3) // 4)
    return f"0x{v:0{width}x}"


def _reset(doc: dict) -> int:
    code = doc.get("code") or {}
    return int(code.get("reset_vector", code.get("base", 0)))


# ---------------------------------------------------------------------------
# 校验
# ---------------------------------------------------------------------------


def validate(doc: dict) -> list[str]:
    problems: list[str] = []
    dev = doc.get("device") or {}
    name = dev.get("id", dev.get("model", "?"))
    code = doc.get("code")
    if not code:
        problems.append(f"{name}: 缺 [code] 段")
        return problems

    width = _addr_width(doc)
    limit = 1 << width
    cb, cs = int(code["base"]), int(code["size"])
    if cb + cs > limit:
        problems.append(f"{name}: code {cb:#x}+{cs:#x} 超出 {width} 位地址空间")
    reset = _reset(doc)
    if not (cb <= reset < cb + cs):
        problems.append(f"{name}: reset_vector {reset:#x} 不在 code 区间内")

    # 同一 kind 的空间重叠（排除 alias_of / conflicts_with 标注的）
    by_kind: dict[str, list[dict]] = {}
    for m in doc.get("memory") or []:
        by_kind.setdefault(m["kind"], []).append(m)
        end = int(m["base"]) + int(m["size"])
        if end > limit:
            problems.append(f"{name}: {m['kind']} {m['base']:#x}+{m['size']:#x} 越界")
    for kind, items in by_kind.items():
        for i in range(len(items)):
            for j in range(i + 1, len(items)):
                a, b = items[i], items[j]
                if a.get("alias_of") or b.get("alias_of"):
                    continue
                a0, a1 = int(a["base"]), int(a["base"]) + int(a["size"])
                b0, b1 = int(b["base"]), int(b["base"]) + int(b["size"])
                if a0 < b1 and b0 < a1:
                    problems.append(
                        f"{name}: {kind} 空间重叠 {a0:#x}-{a1:#x} vs {b0:#x}-{b1:#x}")

    eeprom = _mem(doc, "eeprom")
    if eeprom and eeprom.get("in_flash"):
        e0 = int(eeprom["base"])
        if not (cb <= e0 < cb + cs):
            problems.append(f"{name}: eeprom 标注 in_flash 但不在 code 区")

    xfr = _mem(doc, "xfr")
    if xfr and not xfr.get("mode"):
        problems.append(f"{name}: xfr 缺 mode（dpx_window/movx_dptr_overlap/…）")

    stack = doc.get("stack") or {}
    if stack and stack.get("space") and not _mem(doc, stack["space"]):
        problems.append(f"{name}: stack.space={stack['space']} 无对应 memory 段")
    return problems


# ---------------------------------------------------------------------------
# 生成器
# ---------------------------------------------------------------------------


def emit_sdcc_args(doc: dict) -> str:
    code = doc["code"]
    width = _addr_width(doc)
    out: list[str] = ["--model-large"]
    out += ["--code-loc", _hex(int(code["base"]), width)]
    out += ["--code-size", hex(int(code["size"]))]
    link = doc.get("link") or {}
    data = _mem(doc, "data")
    idata = _mem(doc, "idata")
    if data:
        out += ["--data-loc", hex(int(link.get("data_loc", data["base"])))]
    if idata:
        out += ["--idata-loc", hex(int(link.get("idata_loc", idata["base"])))]
    if data or idata:
        total = int((data or {}).get("size", 0)) + int((idata or {}).get("size", 0))
        out += ["--iram-size", hex(total)]
    xdata = _mem(doc, "xdata")
    if xdata:
        out += ["--xram-loc", _hex(int(xdata["base"]), width)]
        out += ["--xram-size", hex(int(xdata["size"]))]
    stack = doc.get("stack") or {}
    if (doc["_core"].get("stack") == "sp") and "top" in stack:
        out += ["--stack-loc", hex(int(stack["top"]))]
    return " ".join(out) + "\n"


def emit_lk(doc: dict, ihx: str = "out.ihx") -> str:
    code = doc["code"]
    width = _addr_width(doc)
    link = doc.get("link") or {}
    lines = ["-muwx", f"-i {ihx}", "-M"]
    lines.append(f"-b HOME = {_hex(int(code['base']), width)}")
    for kind, area, over in (("data", "DSEG", "data_loc"),
                             ("idata", "ISEG", "idata_loc"),
                             ("xdata", "XSEG", None)):
        m = _mem(doc, kind)
        if m:
            base = link.get(over, m["base"]) if over else m["base"]
            lines.append(f"-b {area} = {_hex(int(base), width)}")
    lines.append("-b PSEG = 0x0001")
    lines.append("-b BSEG = 0x0000")
    lines.append("")
    return "\n".join(lines) + "\n"


def emit_crt0(doc: dict) -> str:
    core = doc["_core"]
    stack = doc.get("stack") or {}
    top = int(stack.get("top", 0x100))
    lines = ["; 由 tools/mcs_device.py 依设备描述生成（crt0 骨架）。", ""]
    lines += ["\t.module crt0"]
    if core.get("stack") == "spx":
        lines += [
            "\t.area PSEG    (PAG,XDATA)",
            "\t.area DSEG    (DATA)",
            "\t.area ISEG    (DATA)",
            "\t.area BSEG    (BIT)",
            "\t.area HOME    (CODE)",
            "",
            "\t.globl _main",
            "",
            "\tejmp __start",
            "",
            "__start:",
            f"\tmov  spx,#{_hex(top, 16)}",
            "\tecall _main",
            "\tsjmp .",
        ]
    else:
        lines += [
            "\t.area CSEG    (CODE)",
            "",
            "\t.globl _main",
            "",
            "\tljmp __start",
            "",
            "__start:",
            f"\tmov  sp,#{_hex(top, 8)}",
            "\tlcall _main",
            "\tsjmp .",
        ]
    return "\n".join(lines) + "\n"


def emit_compiler_json(doc: dict) -> str:
    """给 MCS 后端读的内存模型（紧凑单行 JSON，见 codegen/mcs/device.zig）。"""
    code = doc["code"]
    dev = doc.get("device") or {}
    spaces: dict[str, dict] = {}
    for m in doc.get("memory") or []:
        spaces[m["kind"]] = {"base": int(m["base"]), "size": int(m["size"])}

    def default_data() -> str:
        for k in ("xdata", "edata", "data"):
            if int(spaces.get(k, {}).get("size", 0)) > 0:
                return k
        return "xdata"

    return json.dumps({
        "id": dev.get("id"),
        "arch": dev.get("arch", "mcs251"),
        "code": {"base": int(code["base"]), "size": int(code["size"])},
        "spaces": spaces,
        "default_data": default_data(),
    }, separators=(",", ":")) + "\n"


def emit_summary(doc: dict) -> str:
    dev = doc.get("device") or {}
    core = doc.get("_core") or {}
    fam = doc.get("_family") or {}
    lines = [
        f"id          : {dev.get('id')}",
        f"model       : {dev.get('model')}",
        f"family      : {dev.get('family')}  ({fam.get('label', '-')})",
        f"core        : {dev.get('family')} -> {core.get('note', '-')}",
        f"periph group: {fam.get('peripheral_group', '-')}",
        f"pointer bits: {core.get('pointer_bits', '-')}, endian={core.get('endian', '-')}",
        f"code        : {_hex(int(doc['code']['base']), _addr_width(doc))} "
        f"+{doc['code']['size']:#x}",
    ]
    for m in doc.get("memory") or []:
        extra = []
        if m.get("mode"):
            extra.append(f"mode={m['mode']}")
        if m.get("enable"):
            extra.append(f"enable={m['enable']}")
        if m.get("alias_of"):
            extra.append(f"alias_of={m['alias_of']}")
        tail = ("  [" + ", ".join(extra) + "]") if extra else ""
        lines.append(f"  memory    : {m['kind']:<16} {_hex(int(m['base']), _addr_width(doc))}"
                     f" +{m['size']:#x}{tail}")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# 自测
# ---------------------------------------------------------------------------


def _self_test() -> int:
    root = Path(__file__).resolve().parent.parent
    devdir = root / "devices" / "stc"
    cases = {
        "ai8051u-34k64.toml": (0xFF0000, "mcs251", 24),
        "ai8h8k64u.toml": (0x0000, "fast8051", 16),
        "stc8h8k64u.toml": (0x0000, "fast8051", 16),
        "stc89c52rc.toml": (0x0000, "classic8051", 16),
        "stc12c5a60s2.toml": (0x0000, "fast8051", 16),
        "stc15w4k32s4.toml": (0x0000, "fast8051", 16),
        "iap15f2k61s2.toml": (0x0000, "fast8051", 16),
        "stc32g12k128.toml": (0x000000, "mcs251", 24),
    }
    failed = 0
    for fn, (base, core_note, width) in cases.items():
        p = devdir / fn
        if not p.is_file():
            print(f"SKIP {fn}: 不存在")
            continue
        doc = load_device(p)
        problems = validate(doc)
        if problems:
            failed += 1
            print(f"FAIL {fn}:")
            for x in problems:
                print("      " + x)
            continue
        assert doc["code"]["reset_vector"] == base, fn
        assert doc["_core"]["note"] == core_note or doc["_core"]["stack"], fn
        assert _addr_width(doc) == width, fn
        assert emit_sdcc_args(doc).startswith("--model-large"), fn
        assert "-b HOME = " in emit_lk(doc), fn
        assert "_main" in emit_crt0(doc), fn
        print(f"ok   {fn}")
    if failed:
        print(f"\n{failed} 个设备文件校验失败")
        return 1
    print("\nmcs_device self-test passed")
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="设备描述加载/校验/生成")
    ap.add_argument("device", nargs="?", help="设备 TOML 路径")
    ap.add_argument("--emit", default="summary",
                    choices=["summary", "sdcc-args", "lk", "crt0", "validate", "compiler-json"])
    ap.add_argument("--ihx", default="out.ihx", help="--emit lk 时的输出文件名")
    ap.add_argument("--expand", metavar="MATRIX", help="按 model_matrix.toml 生成每型号 TOML")
    ap.add_argument("--out-dir", help="--expand 的输出目录")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv)

    if args.self_test:
        return _self_test()
    if args.expand:
        if not args.out_dir:
            ap.error("--expand 需要 --out-dir")
        return expand(Path(args.expand), Path(args.out_dir))
    if not args.device:
        ap.error("需要设备 TOML 路径（或 --self-test）")

    path = Path(args.device)
    if not path.is_file():
        print(f"找不到设备文件: {path}", file=sys.stderr)
        return 2
    doc = load_device(path)
    problems = validate(doc)
    if args.emit == "validate":
        if problems:
            for x in problems:
                print(x)
            return 1
        print("ok")
        return 0
    if problems:
        for x in problems:
            print("warning: " + x, file=sys.stderr)
    if args.emit == "summary":
        sys.stdout.write(emit_summary(doc))
    elif args.emit == "sdcc-args":
        sys.stdout.write(emit_sdcc_args(doc))
    elif args.emit == "lk":
        sys.stdout.write(emit_lk(doc, args.ihx))
    elif args.emit == "crt0":
        sys.stdout.write(emit_crt0(doc))
    elif args.emit == "compiler-json":
        sys.stdout.write(emit_compiler_json(doc))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
