# mcs251 — Repository README (English)

> This file was the root `README.md`; all docs now live in `docs/`.
> The root `README.md` is just a pointer into `docs/`.

Zig + C toolchain workspace for Intel 8051 (MCS-51) and 80251 (MCS-251), targeting STC parts.

Plan: Zig frontend + MCS backend emitting SDCC/ASxxxx assembly; C goes through
`sdcc -mmcs51` / `sdcc -mmcs251`; final link with SDCC `sdld` and SDCC runtime.
See [PLAN-计划.md](PLAN-计划.md).

## Layout

    mcs251/
      README.md        repo entry, points into docs/
      docs/            all docs: 01-11, PLAN, repository READMEs
      examples/        Buildable C + Zig projects (ai8051u_blink, ai8051u_ptrtest)
      examples/        Minimal examples
      include/         SDCC headers: c51.h, ai8051u_sfr.h, mcs_intrins.h
      port/            STC AI8051U HAL (SDCC) and target-description tests
      driver/          build scripts (build.ps1, crt0-*.asm; docs in docs/08)
      zig/             Zig compiler source, rebased onto upstream branch `0.16.x`, with the MCS backend
      compiler（系统 zig 重建）/  the only usable prebuilt 55MB zig.exe (binary, not committed)
      sdcc-c251/       vendored SDCC fork with MCS-51 + MCS-251 targets, used as backend/reference

## Interop contract

- Target option: `-mmcs251` (SDCC), `-mmcs51` (SDCC)
- Adopt SDCC MCS251 ABI revision 2: `sdcc-c251/doc/mcs251/abi.md`
- Interop convention: `--stack-auto` / `__reentrant` on every translation unit
- Object/relocatable: SDCC ASxxxx `.rel`; final image: Intel HEX
- Instruction set reference: STC `AI8051U-*.md` appendix A

## Build (fixed prebuilt compiler)

**Self-hosting the compiler is off the table**: the stage2 `zig.exe` produced by the 55 MB
host build hits integer-overflow / stack-overflow bugs, so it cannot validate backend source
changes (see [07-调试笔记-ptr_rt自举崩溃定位.md](07-调试笔记-ptr_rt自举崩溃定位.md)).

Use the single prebuilt compiler and point `ZIG_LIB_DIR` at the tree's own `lib/` so it loads
the `std` carrying the `mcs51`/`mcs251` target definitions:

    $env:ZIG_LIB_DIR = "<workspace>\mcs251\compiler\lib"
    $zig = "<workspace>\mcs251\compiler\zig-out\bin\zig.exe"
    & $zig version   # 0.16.1

Smoke test (MCS-251, void leaf function):

    & $zig build-obj -target mcs251-freestanding -femit-bin=empty.asm empty.zig

> `compiler（系统 zig 重建）/` is git-ignored, the binary is not committed. This build lacks the
> `.ptr_rt` fix; see [01-环境准备.md](01-环境准备.md) section 3. The fix can be worked
> around in source (a `*u8` dereference form), see
> [07](07-调试笔记-ptr_rt自举崩溃定位.md).

## Status

The self-hosted MCS backend (`compiler/src/codegen/mcs/`) builds and emits ASxxxx assembly for:

- 1-4 byte scalar parameters/returns with the ABI register slots (`DPL/DPH/B/A`);
- the first scalar parameter in registers, remaining scalars read from the reentrant
  hardware stack at the SDCC `-(2 + Σsize)` offsets (see `abi.md`);
- 1-4 byte integer `add`/`sub`/`and`/`or`/`xor` (byte-wise with a carry chain), `not`,
  and `shl`/`shr` with constant or variable shift counts;
- multiply (`mul ab`, `mul WR,WR`, and a 3×16×16 composition for 4 bytes) and
  divide/modulo (`div ab`, `div WR,WR`, restoring division for 3/4 bytes); signed
  division/modulo is done by `|a| / |b|` followed by sign fix-up (`@divTrunc`/`@divFloor`,
  `@rem`/`@mod`);
- an SPX stack frame on MCS-251 for temporaries and locals, with `inc/dec spx,#n`
  prologue/epilogue;
- control flow: `.block`/`.loop`/`.repeat`/`.br`/`.cond_br`/`.switch_br`, plus integer
  comparisons (signed and unsigned), `if`/`while`/`for` loops, and `switch` (equal-value
  and range cases lowered to a comparison chain);
- frame-backed locals (`.alloc`/`.load`/`.store`), integer casts
  (`.intcast`/`.trunc`/`.bitcast`, including sign extension and int<->pointer
  materialization), arrays (compile-time indices use a direct frame offset; runtime
  indices are expanded into a comparison chain over the constant indices), and aggregate
  value copies (constant aggregates via `Value.writeToMemory`, runtime copies byte-wise);
- slices (`.array_to_slice`/`.slice`/`.slice_len`/`.slice_ptr`/`.slice_elem_val`/
  `.slice_elem_ptr`/`.ptr_add`) of fixed-length objects: compile-time `ptr`+`len` collapse
  to a slice view; a materialized slice is a 6-byte `ptr`+`len` value (3-byte flat pointer
  kept in `DR28`), runtime indices are expanded over the known length, and pointers use
  `@DR28` dereference;
- direct calls (`.call`) and recursion (first scalar in `DPL/DPH/B/A`, remaining scalars
  pushed in reverse order), indirect calls (3-byte function pointer loaded into `DR28`
  via push/pop, then `ecall @dr28`), and variadic calls (`@cVaStart`/`@cVaArg`/`@cVaCopy`/
  `@cVaEnd`; the promoted `c_int` varargs are pushed with the fixed stack args and read
  through a 3-byte flat `va_list` using `@DR28`).

`MCS-51` keeps the register model for 1-3 byte scalars, fetches additional parameters
from the hardware stack at entry, and keeps locals, parameters and intermediates in a
**static idata frame** (`.area DSEG` / `_frkN` / `.ds`), i.e. the SDCC default
non-reentrant layout.  Callers push arguments (little-endian) and restore `SP` after the
call.
Still unimplemented (each reports a clear compile error): floats, runtime indexing of
unbounded slice/pointer values, and MCS-51 slices and indirect/variadic calls.  The
`sdas`/`sdld` link driver lives in `driver/`.

## Notes

- This is a fork-in-place workspace; `zig/` and `sdcc-c251/` are modified directly.
- Upstream revisions were copied without `.git`. Local changes are tracked by the root repo.
