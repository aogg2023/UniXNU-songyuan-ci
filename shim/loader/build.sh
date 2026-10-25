#!/bin/bash
# 由 data-a-live/shim/loader/build.sh 改写：用 Linux 的 LLVM 工具链，而非 Windows NDK。
# 用法: build.sh [OUTDIR]   （OUTDIR 里需要有 payload.bin，默认 ../payload）
set -euo pipefail
cd "$(dirname "$0")"
out=${1:-/mnt/c/Users/Administrator/Documents/deepseek-harness/default-workspace/bringup_work/songyuan/payload}
[ -f "$out/payload.bin" ] || { echo "缺 $out/payload.bin" >&2; exit 1; }
T=${LLVM_BIN:-/usr/lib/llvm-18/bin}
flags=(--target=aarch64-none-elf -O2 -ffreestanding -fno-builtin -nostdlib -fno-pic
       -fno-stack-protector -mgeneral-regs-only -mstrict-align -Wall -Wextra -Werror)
# QEMU=1: 串口输出 + QEMU 的 RAM 范围（真机上没有这两个地址）
if [ -n "${QEMU:-}" ]; then
    flags+=(-DQEMU_SERIAL -DRAM_LO=0x40000000ull -DRAM_HI=0x140000000ull)
fi
o=$out/loader; mkdir -p "$o"
"$T/clang" "${flags[@]}" -c start.S   -o "$o/start.o"
"$T/clang" "${flags[@]}" -DPAYLOAD="\"$out/payload.bin\"" -c payload.S -o "$o/payload.o"
"$T/clang" "${flags[@]}" -c loader.c  -o "$o/loader.o"
# 加载地址未知：C 里不允许绝对重定位
if "$T/llvm-readelf" -r "$o/loader.o" | grep -q R_AARCH64_ABS; then
    echo "loader.c 里有绝对重定位" >&2; exit 1
fi
"$T/ld.lld" -T loader.ld --build-id=none "$o/start.o" "$o/loader.o" "$o/payload.o" -o "$o/loader.elf"
"$T/llvm-objcopy" -O binary "$o/loader.elf" "$o/Image"
python3 - "$o/Image" "$out/payload.bin" <<'PY'
import struct, sys
img = open(sys.argv[1], 'rb').read(); pl = open(sys.argv[2], 'rb').read()
size = struct.unpack_from('<Q', img, 16)[0]
assert img[0x38:0x3c] == b'ARM\x64', 'no arm64 Image magic'
assert size == len(img), (hex(size), hex(len(img)))
off = img.find(pl[:64])
assert off > 0 and off % 4096 == 0 and img[off:off + len(pl)] == pl, 'payload not embedded'
print('Image %d bytes, payload at 0x%x (%d bytes)' % (len(img), off, len(pl)))
PY
python3 ../../tools/mkbootimg_v4.py "$o/Image" "$o/loader-boot.img"
python3 ../../tools/bootimg_info.py "$o/loader-boot.img"
sha256sum "$o/loader-boot.img"