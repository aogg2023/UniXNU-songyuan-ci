#!/bin/bash
# check_4k_invariants.sh - 在编译前静态校验 4 KiB 页的不变量
#
# 思路来自 https://unixnu.com/zh/xnu/four-k-page-tables 的
# scripts/check-xnu-granules.py / check-native-4k-policy.py，
# 但改为对"已打补丁的源码树"做文本断言，不需要编译，几秒出结果。
#
# 用法: check_4k_invariants.sh <已打补丁的 xnu 树>
set -uo pipefail

TREE=${1:?用法: check_4k_invariants.sh <patched-xnu-tree>}
fail=0
ok()   { printf '  [OK]   %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; fail=$((fail + 1)); }
warn() { printf '  [WARN] %s\n' "$*"; }

have() { grep -q -- "$1" "$2" 2>/dev/null; }

echo "== 1. 机型注册 =="
if have 'MACHINE_FLAGS_ARM64_SONGYUAN' "$TREE/makedefs/MakeInc.def"; then
    ok "MakeInc.def 里有 MACHINE_FLAGS_ARM64_SONGYUAN"
    if grep -q 'MACHINE_FLAGS_ARM64_SONGYUAN.*-DPANDORA=1' "$TREE/makedefs/MakeInc.def"; then
        ok "沿用 -DPANDORA=1（复用已调好的代码路径）"
    else
        warn "没有 -DPANDORA=1：PANDORA 守卫的代码不会编进来"
    fi
    if grep -q 'MACHINE_FLAGS_ARM64_SONGYUAN.*XNU_NATIVE_CS_HASH_CACHE' "$TREE/makedefs/MakeInc.def"; then
        ok "4 KiB 签名哈希缓存开关已并入"
    else
        bad "缺 -DXNU_NATIVE_CS_HASH_CACHE=1"
    fi
else
    bad "没有 MACHINE_FLAGS_ARM64_SONGYUAN（机型未注册）"
fi
[ -f "$TREE/config/MASTER.arm64.songyuan" ] && ok "config/MASTER.arm64.songyuan 存在" \
    || bad "缺 config/MASTER.arm64.songyuan"

echo "== 2. 不进 arm64e（无 PAC 时不能走 arm64e）=="
if grep -q 'ifeq ($(filter SWEET FUXI SONGYUAN,$(CURRENT_MACHINE_CONFIG)),)' "$TREE/makedefs/MakeInc.def"; then
    ok "SONGYUAN 已被排除出 arm64e"
else
    bad "SONGYUAN 仍在 arm64e 路径（会要求指针认证）"
fi

echo "== 3. 4 KiB 页开关 =="
if have '__ARM64_PMAP_SUBPAGE_L1__ 1' "$TREE/pexpert/pexpert/arm64/SWEET.h"; then
    ok "SWEET.h 有 __ARM64_PMAP_SUBPAGE_L1__"
    if grep -q 'defined(PANDORA) || defined(SONGYUAN)' "$TREE/pexpert/pexpert/arm64/SWEET.h"; then
        ok "4 KiB 分支对 PANDORA/SONGYUAN 生效"
    else
        warn "4 KiB 分支的守卫条件里没有 SONGYUAN"
    fi
else
    bad "缺 __ARM64_PMAP_SUBPAGE_L1__（会退回 16 KiB）"
fi

echo "== 4. bootstrap 页表容量 =="
if grep -q 'BOOTSTRAP_TABLE_SIZE (ARM_PGBYTES \* 16)' "$TREE/osfmk/arm/pmap/pmap.h"; then
    ok "BOOTSTRAP_TABLE_SIZE = 16 页（原生 4K 预算）"
else
    bad "没有原生 4 KiB 的 16 页预算"
fi
if have 'BOOTSTRAP_TABLE_BYTES' "$TREE/osfmk/arm64/start.s"; then
    ok "start.s 使用 BOOTSTRAP_TABLE_BYTES（容量守卫接线正确）"
else
    bad "start.s 没有用 BOOTSTRAP_TABLE_BYTES"
fi

echo "== 5. 运行时页大小策略 =="
if grep -q 'PAGE_SHIFT_CONST = ARM_PGSHIFT' "$TREE/osfmk/arm/arm_init.c"; then
    ok "PAGE_SHIFT_CONST 跟随 ARM_PGSHIFT"
else
    bad "PAGE_SHIFT_CONST 未跟随硬件页大小（1 GiB 以上会切成 16 KiB）"
fi
if grep -q 'page_shift_user32 = ARM_PGSHIFT' "$TREE/osfmk/arm/arm_init.c"; then
    ok "page_shift_user32 跟随 ARM_PGSHIFT"
else
    warn "page_shift_user32 未跟随（32 位用户态会拿到 14）"
fi

echo "== 6. 4 GiB 以上物理地址 =="
if grep -q 'vm_offset_t pa = (vm_offset_t)pp << PAGE_SHIFT' "$TREE/osfmk/arm/pmap/pmap.c"; then
    ok "pmap_sync_page_attributes_phys 先加宽再移位（>4 GiB 不溢出）"
elif grep -q 'ptoa(pp)' "$TREE/osfmk/arm/pmap/pmap.c"; then
    ok "pmap_sync_page_attributes_phys 用 ptoa()"
else
    bad "pmap_sync_page_attributes_phys 可能仍是 32 位截断（本机 DRAM 在 0x8c0000000）"
fi

echo "== 7. 代码签名 granule 桥接 =="
if have 'csb_native4k_hashes' "$TREE/bsd/kern/ubc_subr.c"; then
    ok "csb_native4k_hashes 已接入 cs_validate_page"
else
    bad "缺 4 KiB 签名哈希缓存（16 KiB CodeDirectory 无法校验）"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "结论：4 KiB 不变量全部满足（0 个 FAIL）"
    exit 0
fi
echo "结论：$fail 项不满足，先修再编译"
exit 1
