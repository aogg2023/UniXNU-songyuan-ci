# UniXNU 文档蒸馏（针对 songyuan 的可执行结论）

来源：`https://unixnu.com/zh/` 的 porting / reference / xnu 章节，
抓取日期 2026-10-25。**外部文档只作知识来源**，具体数值一律以本机实测为准。

---

## 1. 两套栈的根本差别

| 层 | UniXNU | 本项目（data-a-live 路线） |
|---|---|---|
| 1 启动镜像 | BootShim（Android boot.img 壳） | 自写 loader + `fastboot boot` |
| 2 UEFI 固件 | Mu-Silicium（`SILICIUM_UEFI.fd`） | 无（直接用 ABL 的 EL1 环境） |
| 3 启动管理器 | `UniXNU.efi`（OpenCore 式菜单） | 无 |
| 4 XNU 加载器 | DarwinBoot（UEFI 驱动） | `shim/loader`（裸机，MMU off） |
| 5 内核 | XNU + prelink | XNU + 我们 196 补丁序列 ✅ |
| 6 用户态 | IPSW 的 `OS`/`SystemOS` | 待做 |

**结论：我们的第 1/4 层已自研通过，第 5 层已建成。UniXNU 的第 2/3 层我们不需要**
（那套是为了在没有可编程 bootloader 的设备上造一个 UEFI 环境；我们这台 ABL 直接给 EL1）。

值得抄的是**第 5 层的 4 KiB 知识**和**验证方法**，不是它的固件栈。

---

## 2. 4 KiB 页表：可直接照做的知识点

### 2.1 granule 常量

| 机型 | `ARM_PGSHIFT` | `ARM_PGBYTES` | `TCR_EL1_BOOT` TG0 | TG1 |
|---|---|---|---|---|
| BCM2837（native 4K profile） | 12 | 4096 | 0（4 KiB） | 2（4 KiB） |
| VMAPPLE | 14 | 16384 | 2（16 KiB） | 1（16 KiB） |

**BCM2837 就是 XNU 里现成的"原生 4 KiB"机型配置。** 我们的 SONGYUAN 走的是
pandora 的 `__ARM64_PMAP_SUBPAGE_L1__` 路径，效果等价。

### 2.2 bootstrap 页表容量（我们已有）

补丁 `native-4k-bootstrap-capacity`（我们编号 `0103-unixnu-*`）：

```c
#elif !defined(APPLE_ARM64_ARCH_FAMILY) && !__ARM_16K_PG__
/* 两个根，加上每 6 GiB 映射最多七个 L2 页。 */
#define BOOTSTRAP_TABLE_SIZE (ARM_PGBYTES * 16)
```

容量守卫（分配新 L2 前）：

```asm
add $6, x25, #(BOOTSTRAP_TABLE_BYTES >> 12), lsl #12
cmp $4, $6
b.hs Lbootstrap_tables_exhausted
```

> 文档原话："耗尽标签在循环中停住，游标和结束地址保留在寄存器中。
> 此时 MMU 未开启，调试器可以直接查看寄存器。"

**这条对我们排查极有价值**：若看到 CPU 停在某个物理地址死循环且 MMU off，
就是容量耗尽，不是映射错误。

### 2.3 运行时页大小（我们已有）

`native-4k-user-abi`：任何 RAM 大小下都用硬件页大小，不做 Apple 的
"1 GiB 以上切 16 KiB"。

### 2.4 代码签名（我们已有）

`native-4k-signature-hash-cache`：接受 `pageSize = 14` 的 CodeDirectory，
按原始 16 KiB 块校验后派生每 4 KiB 页摘要，存入 `csb_native4k_hashes`。
开关 `XNU_NATIVE_CS_HASH_CACHE`（已并入我们的 `0103-songyuan-*`）。

### 2.5 分配器对齐 / 4 GiB 以上物理地址

| 补丁 | 作用 | 我们的状态 |
|---|---|---|
| `pgz-aligned-validation` | 页掩码检查前先解码 PGZ 地址 | **缺** |
| `zzx-pmap-sync-64bit-pa` | `pmap_sync_page_attributes_phys` 用 `ptoa()` 避免 32 位截断 | **已等价修复**（`0101` 里 `(vm_offset_t)pp << PAGE_SHIFT`，注释明确） |

> `pgz-aligned-validation` 值得评估：它影响非 Apple 平台的 zone 分配器校验。

### 2.6 非 Apple 平台保护（我们缺 6 个）

`apple-only-cpu-tunables`、`non-apple-cache-monitor`、`non-apple-iommu-bootstrap`、
`non-apple-pmap-field`、`source-machine-layer`、`native-arm-pan`。

这些是 UniXNU 为"完全没有 Apple 闭源库"的构建补的。我们的构建**能过链接**，
说明 data-a-live 的补丁集已用自己的方式覆盖了同类问题（`0005-non-pac-build-fixes`
`0007/0008/0009` 等）。**暂不引入**，除非遇到具体症状。

---

## 3. QEMU 验证判据（照抄成检查表）

UniXNU 给出的内核入口观察项：

| 寄存器/符号 | 期望值 |
|---|---|
| `TCR_EL1` TG0 | 0（4 KiB） |
| `TCR_EL1` TG1 | 2（4 KiB） |
| `SCTLR_EL1` M | 1（MMU 开） |
| `TTBR0_EL1`、`TTBR1_EL1` | 非零 |
| `_PAGE_SHIFT_CONST`、`_page_shift`、`_page_shift_user32`、`_page_size` | 12 / 12 / 12 / 4096 |

**我们目前的短板**：QEMU 8.2 的 HMP `info registers` 不打印系统寄存器。
补救办法（按成本排序）：

1. 在 loader 里跳转前读 `TCR_EL1`/`SCTLR_EL1`/`TTBR0_EL1`/`TTBR1_EL1` 打到串口
   （跳转前 MMU 关闭，读到的是 ABL/QEMU 的值，能验证"进入内核时环境是否干净"）
2. 用 `qemu-system-aarch64 -s -S` + gdbstub，在 `_arm_init` 下断点，断不到即证实"调用前死"
3. 用 `-d in_asm` 记录执行流，看最后成功取指的指令

第 2 条最直接：**能在 `_arm_init` 断住 → 映射没问题，问题在更后面；断不住 → 证实我们的判断**。

---

## 4. 与当前卡点的对照

| UniXNU 文档线索 | 我们的现状 | 是否适用 |
|---|---|---|
| bootstrap 容量每 GiB 预算 | 5 GiB 需 12 页 ≤ 16 页 | ✅ 容量够，已排除 |
| 容量耗尽的症状 = MMU off 死循环 | 我们见到的是 **MMU on + Prefetch Abort** | ❌ 不是耗尽 |
| `zzx-pmap-sync-64bit-pa` | 已被 `0101` 等价修复 | ❌ 无需引入 |
| `pgz-aligned-validation` | 未修 | ⚠️ 待评估（不解释当前崩溃） |
| 内核入口 panic 检查"页表、内核窗口、启动参数" | 三项都在查 | ✅ 方向一致 |
| QEMU 停点工具 `gdb-stop.py` | 我们只有 HMP 轮询 | 🔧 值得自建（见 §3 第 2 条） |

**净结论：UniXNU 文档没有直接给出我们这个崩溃的答案，但它确认了两件事**——
（a）4 KiB 路线的已知坑我们基本都补了；（b）下一步该用 **gdbstub 在 `_arm_init` 下断点**，
把"映射缺失"从推断变成事实。

---

## 5. 从 UniXNU 抄来的、已落地的检查

见 `tools/check_4k_invariants.sh`：静态校验构建树里的 4 KiB 不变量
（`PAGE_SHIFT_CONST`、`BOOTSTRAP_TABLE_SIZE`、`__ARM64_PMAP_SUBPAGE_L1__`、
`XNU_NATIVE_CS_HASH_CACHE`、arm64e 排除），可在 CI 里编译前跑，几秒出结果。
