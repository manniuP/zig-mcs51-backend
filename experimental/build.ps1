#!/usr/bin/env pwsh
# experimental/build.ps1 -- self-contained experimental build (opt-tags branch)
#
# Builds the MCS compiler from this tree with the system zig, then compiles/links the
# example in examples/<Example>. Post-processing tools (tools/*.py) are run directly
# with Python -- Python is NOT frozen into a binary (no mcstools.exe).
#
# Requires: system zig 0.16.x on PATH; python on PATH; SDCC (mcs251) with sdas251/sdcc.
# Examples:
#   powershell -File experimental/build.ps1
#   powershell -File experimental/build.ps1 -SkipCompiler -Loop
param(
    [string]$Example = "ai8051u_zig_opt",
    [string]$Source  = "opt.zig",
    [string]$Stem    = "opt",
    [string]$Device  = "ai8051u-34k64",
    [string]$Sdcc    = "sdcc",
    [string]$Zig     = "zig",
    [switch]$Loop,
    [switch]$Small,
    [switch]$SkipCompiler
)
$ErrorActionPreference = "Stop"
$exp  = $PSScriptRoot
$repo = Split-Path -Parent $exp
$py   = (Get-Command python).Source

function Step($m) { Write-Host ("== " + $m) }

# 1) Build the MCS compiler (system zig; MCS backend only)
if (-not $SkipCompiler) {
    Step "zig build -Doptimize=ReleaseFast -Dno-lib -Dmcs-only"
    Push-Location $repo
    try { & $Zig build -Doptimize=ReleaseFast -Dno-lib -Dmcs-only "--zig-lib-dir=$repo\lib" }
    finally { Pop-Location }
}
$mcs = Join-Path $repo "zig-out/bin/zig.exe"
if (-not (Test-Path $mcs)) { $mcs = Join-Path $repo "zig-out/bin/zig" }
if (-not (Test-Path $mcs)) { throw "compiler not found (build it first without -SkipCompiler): $mcs" }

# 2) Runtime env (this tree's lib / private cache; device table -> MCS_DEVICE)
$env:ZIG_LIB_DIR = Join-Path $repo "lib"
$env:ZIG_GLOBAL_CACHE_DIR = Join-Path $repo ".zig-cache"
New-Item -ItemType Directory -Force -Path $env:ZIG_GLOBAL_CACHE_DIR | Out-Null
$devToml = Join-Path $exp "devices/stc/$Device.toml"
if (-not (Test-Path $devToml)) { throw "device table not found: $devToml" }
$env:MCS_DEVICE = ((& $py (Join-Path $exp "tools/mcs_device.py") $devToml --emit compiler-json) -join "`n").TrimEnd()
if ($Loop) { $env:MCS_LOOP = "1" } else { Remove-Item Env:\MCS_LOOP -ErrorAction SilentlyContinue }

$dir     = Join-Path $exp "examples/$Example"
$src     = Join-Path $dir $Source
$asm     = Join-Path $dir "$Stem.asm"
$rel     = Join-Path $dir "$Stem.rel"
$crt0    = Join-Path $dir "crt0.asm"
$crt0rel = Join-Path $dir "crt0.rel"
$ihx     = Join-Path $dir "$Stem.ihx"
foreach ($f in @($src, $crt0)) { if (-not (Test-Path $f)) { throw "missing source: $f" } }

# 3) Zig -> asm
Step "[1/5] Zig -> asm : $Source"
$optFlag = if ($Small) { "-OReleaseSmall" } else { "-ODebug" }
& $mcs build-obj $optFlag "-target" "mcs251-freestanding" `
    "--dep" "mcs" "-Mroot=$src" "-Mmcs=$(Join-Path $exp 'lib/mcs251.zig')" "-femit-bin=$asm"

# 4) Build-layer post-processing (Python direct; same order as mcs251 xmake/helpers.lua)
Step "[2/5] postprocess (python)"
& $py (Join-Path $exp "tools/fix_mcs_labels.py") $asm
& $py (Join-Path $exp "tools/mcs_opt.py") $asm
& $py (Join-Path $exp "tools/mcs_ir.py") $asm
& $py (Join-Path $exp "tools/mcs_loop.py") $asm
& $py (Join-Path $exp "tools/mcs_overlay.py") $asm

# 5) Assemble + link (needs SDCC)
$sdccExe = (Get-Command $Sdcc -ErrorAction SilentlyContinue).Source
if (-not $sdccExe) {
    Write-Warning "SDCC ($Sdcc) not found; asm generated at $asm. Install SDCC (mcs251) or pass -Sdcc <path>."
    return
}
$sdas = Join-Path (Split-Path -Parent $sdccExe) "sdas251.exe"
if (-not (Test-Path $sdas)) { $sdas = Join-Path (Split-Path -Parent $sdccExe) "sdas251" }
if (-not (Test-Path $sdas)) { throw "sdas251 not found (should sit next to sdcc): $sdas" }

Step "[3/5] asm -> rel : $Stem.asm"
& $sdas "-plosgffw" $rel $asm
Step "[4/5] crt0 -> rel: crt0.asm"
& $sdas "-plosgffw" $crt0rel $crt0
Step "[5/5] link -> ihx : $Stem.ihx"
& $sdccExe "-mmcs251" "--model-large" "--code-loc" "0xff0000" `
    "--data-loc" "0x30" "--idata-loc" "0x80" $crt0rel $rel "-o" $ihx
Write-Host ("OK -> " + $ihx)
