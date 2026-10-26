# Windows-native replacement for build.sh (no WSL needed).
#   .\build.ps1                       # payload dir defaults to bringup_work/songyuan/payload
#   .\build.ps1 -Out <dir> [-Qemu]
# Needs: LLVM (clang/ld.lld/llvm-objcopy/llvm-readelf) and Python 3.
param(
    [string]$Out = '',
    [switch]$Qemu,
    [string]$LLVM = 'E:\Android\llvm\bin',
    [string]$Python = 'C:\Users\Administrator\AppData\Local\Programs\Python\Python311\python.exe'
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path (Split-Path $here -Parent) -Parent
# heavy build outputs live on E: (C: is tight); override with -Out or SONGYUAN_WORK
if (-not $Out) {
    $work = if ($env:SONGYUAN_WORK) { $env:SONGYUAN_WORK } else { 'E:\songyuan\bringup_work\songyuan' }
    $Out = Join-Path $work 'payload'
}
$Out = (Resolve-Path $Out).Path
$payload = Join-Path $Out 'payload.bin'
if (-not (Test-Path $payload)) { throw "missing $payload" }

$clang = Join-Path $LLVM 'clang.exe'
$lld = Join-Path $LLVM 'ld.lld.exe'
$objcopy = Join-Path $LLVM 'llvm-objcopy.exe'
$readelf = Join-Path $LLVM 'llvm-readelf.exe'
foreach ($t in @($clang, $lld, $objcopy, $readelf)) {
    if (-not (Test-Path $t)) { throw "missing tool: $t (pass -LLVM <bin dir>)" }
}

$flags = @('--target=aarch64-none-elf', '-O2', '-ffreestanding', '-fno-builtin', '-nostdlib',
    '-fno-pic', '-fno-stack-protector', '-mgeneral-regs-only', '-mstrict-align', '-Wall', '-Wextra', '-Werror')
if ($Qemu) { $flags += @('-DQEMU_SERIAL', '-DRAM_LO=0x40000000ull', '-DRAM_HI=0x140000000ull') }

$o = Join-Path $Out 'loader'
New-Item -ItemType Directory -Force -Path $o | Out-Null
# .incbin takes the path literally; forward slashes keep backslash escapes out of the way
$payloadC = $payload -replace '\\', '/'

Push-Location $here
try {
    & $clang @flags -c start.S -o "$o/start.o"
    if ($LASTEXITCODE) { throw 'start.S failed' }
    & $clang @flags "-DPAYLOAD=`"$payloadC`"" -c payload.S -o "$o/payload.o"
    if ($LASTEXITCODE) { throw 'payload.S failed' }
    & $clang @flags -c loader.c -o "$o/loader.o"
    if ($LASTEXITCODE) { throw 'loader.c failed' }

    $rel = & $readelf -r "$o/loader.o" 2>&1 | Out-String
    if ($rel -match 'R_AARCH64_ABS') { throw 'loader.c has absolute relocations' }

    & $lld -T loader.ld --build-id=none "$o/start.o" "$o/loader.o" "$o/payload.o" -o "$o/loader.elf"
    if ($LASTEXITCODE) { throw 'link failed' }
    & $objcopy -O binary "$o/loader.elf" "$o/Image"
    if ($LASTEXITCODE) { throw 'objcopy failed' }

    # same sanity check as build.sh: payload really embedded, Image header size matches
    $check = @'
import struct, sys
img = open(sys.argv[1], 'rb').read(); pl = open(sys.argv[2], 'rb').read()
size = struct.unpack_from('<Q', img, 16)[0]
assert img[0x38:0x3c] == b'ARM\x64', 'no arm64 Image magic'
assert size == len(img), (hex(size), hex(len(img)))
off = img.find(pl[:64])
assert off > 0 and off % 4096 == 0 and img[off:off + len(pl)] == pl, 'payload not embedded'
print('Image %d bytes, payload at 0x%x (%d bytes)' % (len(img), off, len(pl)))
'@
    $check | & $Python - "$o/Image" $payload
    if ($LASTEXITCODE) { throw 'payload embed check failed' }

    & $Python (Join-Path $here '..\..\tools\mkbootimg_v4.py') "$o/Image" "$o/loader-boot.img"
    if ($LASTEXITCODE) { throw 'mkbootimg failed' }
    & $Python (Join-Path $here '..\..\tools\bootimg_info.py') "$o/loader-boot.img"
    (Get-FileHash "$o/loader-boot.img" -Algorithm SHA256).Hash.ToLower() + "  loader-boot.img"
} finally { Pop-Location }
