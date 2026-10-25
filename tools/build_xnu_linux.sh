#!/bin/bash
# build_xnu_linux.sh - 在 Linux（WSL）上编译 songyuan 内核
#
# 依据：UniXNU 的 scripts/build-xnu-4k-baseline.sh（Linux 路径序列）
#   1) 把 libplatform / libdispatch 头文件铺进 fakeroot
#   2) make installhdrs（用 Linux 工具链，不用 xcodebuild）
#   3) 编 libfirehose_kernel.a
#   4) 编 libcc_kext.a（Mac 上这个从 Apple clang 拿，Linux 上要自己编）
#   5) make 出 kernel
#
# 前置：
#   - /opt/unixnu-linux 工具链（scripts/linux/setup-toolchain.py 装好）
#   - 已打补丁的树（xnu/patches/series.songyuan 全部应用，含 HFS staging）
#
# 用法：build_xnu_linux.sh <已打补丁的 xnu 树> [输出目录]
set -uo pipefail

TREE=${1:?用法: build_xnu_linux.sh <patched-xnu-tree> [outdir]}
OUT=${2:-/tmp/kernel-out}
PREFIX=${UNIXNU_TOOLCHAIN:-/opt/unixnu-linux}
FAKE=/tmp/fakeroot
REFER=/tmp/refer
XS=SONGYUAN
JOBS=${JOBS:-8}
# Linux 没有 sysctl / sw_vers：这三个值用命令行变量覆盖（Makefile 里是 :=，命令行优先）
HOSTVARS=(
  HOST_OS_VERSION=13.5
  SYSCTL_HW_PHYSICALCPU=8
  SYSCTL_HW_LOGICALCPU=12
  MEMORY_SIZE=8589934592
  PLATFORM=iPhoneOS
  HOST_CC=/opt/unixnu-linux/CommandLineTools/usr/bin/xnu-host-cc
  MIGCOM=/opt/unixnu-linux/CommandLineTools/usr/libexec/migcom
)
UNIXNU_SCRIPTS=${UNIXNU_SCRIPTS:-/mnt/c/Users/Administrator/Documents/deepseek-harness/default-workspace/bringup_work/third_party/UniXNU/scripts}

export PATH="$PREFIX/CommandLineTools/usr/bin:$PREFIX/XcodeDefault.xctoolchain/usr/bin:$PREFIX/llvm/bin:$PREFIX/bin:$PATH"
export LD_LIBRARY_PATH="$PREFIX/llvm/lib:/opt/libdispatch/lib:${LD_LIBRARY_PATH:-}"
export KERNEL_SDKROOT=$FAKE

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\n[失败] %s\n' "$*" >&2; exit 1; }

[ -d "$TREE" ] || die "找不到树: $TREE"
[ -f "$TREE/config/MASTER.arm64.songyuan" ] || die "这棵树没有 songyuan 机型配置（0103 没应用？）"
[ -x "$PREFIX/llvm/bin/clang" ] || die "工具链缺失: $PREFIX/llvm/bin/clang（先跑 setup-toolchain.py）"
command -v unifdef >/dev/null || die "缺 unifdef"

mkdir -p "$FAKE" "$OUT" /tmp/kb/obj /tmp/kb/sym

say "0/5 availability.pl 与脚本适配（Linux 专有）"
if [ ! -x "$FAKE/usr/local/libexec/availability.pl" ]; then
    [ -d /tmp/refer/AvailabilityVersions ] || \
        git clone -q --depth 1 https://github.com/apple-oss-distributions/AvailabilityVersions.git /tmp/refer/AvailabilityVersions \
        || die "克隆 AvailabilityVersions 失败"
    make -C /tmp/refer/AvailabilityVersions install DSTROOT="$FAKE" >/tmp/avail.log 2>&1 \
        || { tail -8 /tmp/avail.log; die "availability.pl 安装失败"; }
fi
export XNU_AVAILABILITY_PL="$FAKE/usr/local/libexec/availability.pl"
# UnixNu 的 prepare-xnu.py 负责装这个；它在 iPhoneOS SDK 里，Linux 上没有
mkdir -p "$FAKE/usr/include"
[ -f "$FAKE/usr/include/TargetConditionals.h" ] || \
    cp "$UNIXNU_SCRIPTS/linux/TargetConditionals.h" "$FAKE/usr/include/" 2>/dev/null || \
    echo "  [警告] 没找到 TargetConditionals.h"
echo "  availability.pl: $([ -x "$XNU_AVAILABILITY_PL" ] && echo 就绪 || echo 缺失)"
# xnu-8796 的脚本硬拼 SDKROOT 路径；给它一个环境变量出口（幂等）
if ! grep -q 'XNU_AVAILABILITY_PL' "$TREE/bsd/sys/make_symbol_aliasing.sh"; then
    sed -i 's|^AVAILABILITY_PL="${SDKROOT}/${DRIVERKITROOT}/usr/local/libexec/availability.pl"|AVAILABILITY_PL="${XNU_AVAILABILITY_PL:-${SDKROOT}/${DRIVERKITROOT}/usr/local/libexec/availability.pl}"|' \
        "$TREE/bsd/sys/make_symbol_aliasing.sh"
    echo "  已给 make_symbol_aliasing.sh 加 XNU_AVAILABILITY_PL 出口"
fi

say "1/5 铺 fakeroot 头文件"
mkdir -p "$FAKE/usr/local/include/kernel" \
         "$FAKE/System/Library/Frameworks/Kernel.framework/Versions/A/PrivateHeaders/platform"
cp -R "$REFER/libplatform/include/." "$FAKE/usr/local/include/" 2>/dev/null || true
cp -R "$REFER/libplatform/private/." "$FAKE/usr/local/include/" 2>/dev/null || true
cp -R "$REFER/libplatform/private/platform/." \
      "$FAKE/System/Library/Frameworks/Kernel.framework/Versions/A/PrivateHeaders/platform/" 2>/dev/null || true
mkdir -p "$FAKE/usr/local/include/os"
for h in "$REFER"/libdispatch/os/*.h; do
    unifdef -DKERNEL=1 -DOS_FIREHOSE_SPI=1 -DOS_VOUCHER_ACTIVITY_SPI_TYPES=1 \
            -UOS_VOUCHER_ACTIVITY_SPI "$h" > "$FAKE/usr/local/include/os/$(basename "$h")" 2>/dev/null || \
    cp "$h" "$FAKE/usr/local/include/os/$(basename "$h")"
done
# os/ 下的子目录（internal/、voucher/ …）整棵拷，不做 unifdef
for d in "$REFER"/libdispatch/os/*/; do
    [ -d "$d" ] && cp -R "$d" "$FAKE/usr/local/include/os/"
done
echo "  libplatform 头: $(find "$FAKE/usr/local/include" -name '*.h' | wc -l)"
echo "  libdispatch os: $(ls "$FAKE/usr/local/include/os" | wc -l)"

say "2/5 installhdrs（MACHINE_CONFIGS=$XS）"
make -C "$TREE" installhdrs SDKROOT=macosx ARCH_CONFIGS=ARM64 \
     MACHINE_CONFIGS="$XS" KERNEL_CONFIGS=DEVELOPMENT \
     RC_DARWIN_KERNEL_VERSION=22.6.0 RC_ProjectSourceVersion=8796.141.3 \
     MAKEJOBS=-j"$JOBS" OBJROOT=/tmp/kb/obj SYMROOT=/tmp/kb/sym DSTROOT="$FAKE" \
     "${HOSTVARS[@]}" \
     2>&1 | tee /tmp/xnu-installhdrs.log | tail -20 || die "installhdrs 失败，完整日志 /tmp/xnu-installhdrs.log"

say "3/5 libfirehose_kernel.a"
# 依据 UniXNU scripts/build-firehose.sh 的 Linux 分支：
# 它不是 Xcode 工程，而是一个源文件 + libtool -static。
if [ -f "$FAKE/usr/local/lib/kernel/libfirehose_kernel.a" ]; then
    echo "  已存在，跳过"
else
    WORK=/tmp/libdispatch-work
    rm -rf "$WORK"
    if [ -d /tmp/libdispatch-src/src ]; then
        cp -R /tmp/libdispatch-src "$WORK"          # swift-6.4.0-RELEASE（与 UniXNU 一致）
    else
        cp -R "$REFER/libdispatch" "$WORK"
    fi
    mkdir -p /tmp/firehose/obj "$FAKE/usr/local/lib/kernel" "$FAKE/usr/local/include/kernel/os"
    # firehose 源码要 <internal/atomic.h>，而 libdispatch 现代版本把它放在 os/atomic_private.h
    mkdir -p "$FAKE/usr/local/include/os/internal"
    \
        printf "#pragma once\n#include <src/shims/atomic.h>\n" > "$FAKE/usr/local/include/os/internal/atomic.h"
    "$PREFIX/llvm/bin/clang" -target arm64-apple-ios17.0 -std=gnu11 -Os -g \
        -mkernel -nostdinc -Wno-packed \
        -DKERNEL=1 -DDISPATCH_USE_DTRACE=0 -DOS_ATOMIC_CONFIG_MEMORY_ORDER_DEPENDENCY=1 \
        -DOS_ATOMIC_CONFIG_STARVATION_FREE_ONLY=0 \
        -I"$WORK" \
        -I"$FAKE/System/Library/Frameworks/Kernel.framework/PrivateHeaders" \
        -I"$FAKE/System/Library/Frameworks/Kernel.framework/Headers" \
        -I"$FAKE/usr/local/include/os" -I"$FAKE/usr/local/include/firehose" \
        -I"$FAKE/usr/include" -I"$FAKE/usr/local/include" \
        -I"$TREE/EXTERNAL_HEADERS" \
        -c "$WORK/src/firehose/firehose_buffer.c" -o /tmp/firehose/obj/firehose_buffer.o \
        || die "firehose_buffer.c 编译失败"
    # 用 llvm-ar 顶替 xcrun libtool（静态库格式相同）
    llvm-ar rcs "$FAKE/usr/local/lib/kernel/libfirehose_kernel.a" /tmp/firehose/obj/firehose_buffer.o \
        || die "libfirehose_kernel.a 生成失败"
    unifdef -DKERNEL=1 -DOS_FIREHOSE_SPI=1 -DOS_VOUCHER_ACTIVITY_SPI_TYPES=1 -UOS_VOUCHER_ACTIVITY_SPI \
        -o "$FAKE/usr/local/include/kernel/os/firehose_buffer_private.h" \
        "$WORK/os/firehose_buffer_private.h" || true
    echo "  已生成: $(du -h "$FAKE/usr/local/lib/kernel/libfirehose_kernel.a" | cut -f1)"
fi

say "4/5 libcc_kext.a"
if [ -f "$FAKE/usr/local/lib/kernel/libcc_kext.a" ]; then
    echo "  已存在，跳过"
else
    # UniXNU 的 prepare-xnu.py 用 ROOT=<脚本>/../.. 推导 .cache/{xnu-work,fakeroot}。
    # 造一个 shim 目录 + 两个软链接，就能原样复用，不必改它的代码。
    SHIM=/tmp/unixnu-shim
    rm -rf "$SHIM"; mkdir -p "$SHIM/scripts/linux" "$SHIM/.cache"
    cp "$UNIXNU_SCRIPTS/linux/prepare-xnu.py" "$UNIXNU_SCRIPTS/linux/TargetConditionals.h" "$SHIM/scripts/linux/" 2>/dev/null \
        || die "找不到 prepare-xnu.py（用 UNIXNU_SCRIPTS 指向 UniXNU/scripts）"
    ln -sfn "$TREE" "$SHIM/.cache/xnu-work"
    # 网络对 github 不稳：本地已有目标 commit 时短路 fetch()
    python3 - "$SHIM/scripts/linux/prepare-xnu.py" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "def fetch(directory, url, commit, *paths):\n"
new = (old +
 "    import subprocess as _s\n"
 "    try:\n"
 "        if (directory / \".git\").exists() and _s.run(\n"
 "                [\"git\", \"-C\", str(directory), \"cat-file\", \"-e\", str(commit) + \"^{commit}\"],\n"
 "                capture_output=True).returncode == 0:\n"
 "            return\n"
 "    except Exception:\n"
 "        pass\n")
if old in s and "cat-file" not in s:
    open(p, "w").write(s.replace(old, new, 1))
    print("  已给 prepare-xnu.py 的 fetch() 加本地短路")
PY
    # 复用工具链已经下好的 llvm-project，避免再拉一次（网络不稳）
    LLVM_SRC=$(ls -d /var/tmp/unixnu-toolchain-*/llvm-project 2>/dev/null | head -1)
    if [ -n "$LLVM_SRC" ]; then
        mkdir -p "$SHIM/.cache/linux"
        ln -sfn "$LLVM_SRC" "$SHIM/.cache/linux/llvm-project"
        echo "  llvm-project 复用: $LLVM_SRC"
    fi
    ln -sfn "$FAKE" "$SHIM/.cache/fakeroot"
    ( cd "$SHIM" && python3 scripts/linux/prepare-xnu.py libs ) || die "libcc_kext.a 生成失败"
    echo "  已生成: $(du -h "$FAKE/usr/local/lib/kernel/libcc_kext.a" 2>/dev/null | cut -f1)"
fi

say "5/5 编内核"
make -C "$TREE" SDKROOT=macosx ARCH_CONFIGS=ARM64 \
     TARGET_CONFIGS="DEVELOPMENT ARM64 $XS" \
     RC_DARWIN_KERNEL_VERSION=22.6.0 RC_ProjectSourceVersion=8796.141.3 \
     BUILD_WERROR=0 BUILD_LTO=0 \
     MAKEJOBS=-j"$JOBS" OBJROOT=/tmp/kb/obj SYMROOT=/tmp/kb/sym DSTROOT="$OUT" \
     KERNEL_SDKROOT="$FAKE" "${HOSTVARS[@]}" \
     2>&1 | tee /tmp/kernel-build.log | tail -30

say "产物"
find /tmp/kb "$OUT" -name 'kernel.*' -o -name 'mach.*' 2>/dev/null | head -10
echo
echo "完整日志: /tmp/kernel-build.log"
