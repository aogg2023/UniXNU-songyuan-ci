# 诊断补丁草案：把翻译寄存器存进 boot_args 页

目的：确定 `arm_init` 取指失败到底是**TTBR1 指向别处**还是 **TCR 的 T1SZ 不覆盖该 VA**。
页表已实测证明 KVA 的 `L2[61]`（`0x51A00601`）覆盖 `arm_init` 的物理地址
`0x51AB3488`，所以问题不在表内容，而在**表有没有挂上去 / 有没有走到**。

## 为什么存在 boot_args 页

- `boot_args` 在 `KERN_END` 之后，loader 已把它清零并填好，32 位字段之后是空闲区
- 崩溃后 QEMU 里可以直接 `pmemsave <boot_args PA> 0x1000` 取回
- 偏移 `0x700` 起已超出 `struct boot_args`（736 字节 = 0x2E0），不会覆盖有效字段

## 插入位置

`osfmk/arm64/start.s` 的 `common_start` 末尾、**真正跳到 `arm_init` 之前**
（文件中 `/* Return to arm_init() */` 之后、`blr lr` / `br x?` 之前）。
此时 MMU 已开启，访问 boot_args 必须用 VA。

```asm
	/* SONGYUAN diag: 记录翻译设置，崩溃后可 dump boot_args 页读回。
	 * 此时 MMU 已开：boot_args 的 PA 在 x20，转成 VA 再用。 */
	mov		x9, x20
	add		x9, x9, x22
	sub		x9, x9, x23
	mrs		x10, TTBR0_EL1
	str		x10, [x9, #0x700]
	mrs		x10, TTBR1_EL1
	str		x10, [x9, #0x708]
	mrs		x10, TCR_EL1
	str		x10, [x9, #0x710]
	mrs		x10, SCTLR_EL1
	str		x10, [x9, #0x718]
	mrs		x10, ID_AA64MMFR0_EL1
	str		x10, [x9, #0x720]
```

## 判读方法

取回后按小端解 5 个 u64：

| 偏移 | 寄存器 | 期望 / 含义 |
|---|---|---|
| 0x700 | `TTBR0_EL1` | 应指向 V=P 表的物理地址（低 48 位，去掉 ASID 低 16 位） |
| 0x708 | `TTBR1_EL1` | 应指向 KVA 表的物理地址；**若为 0 或指向别处即根因** |
| 0x710 | `TCR_EL1` | 看 `T1SZ[21:16]`：4K + 39 位 VA 应使可译范围覆盖 `0xfffffe00_xxxxxxxx` |
| 0x718 | `SCTLR_EL1` | bit0 = M 必须为 1 |
| 0x720 | `ID_AA64MMFR0_EL1` | `TGran4[31:28]`、`TGran16[23:20]`、`PARange[3:0]` |

对照我们已实测的值：`TGran16 = 0`（无 16 KiB granule）、`PARange = 44 位`。

## 判读分支

- `TTBR1 == 0` → KVA 根没装：`MSR_TTBR1_EL1_X0` 之前的分支没走到，或 x0 被覆盖
- `TTBR1` 指向的 PA ≠ 池里的 `0x51187000` → 根被重定向（slide 逻辑）
- `T1SZ` 太小 → `0xfffffe00_xxxxxxxx` 超出可译范围，walker 第 0 级即判无效
  （与我们看到的 `DFSC=0x4` 完全吻合）
- 三者都正常 → 问题在 `arm_init` 自身的取指属性（XN 位），查 `SCTLR_EL1.WXN` 与表项 `PXN/UXN`

## 使用方式

1. 存成 `xnu/patches/0103b-songyuan-diag-regs.patch`，并把 `0103b-...` 加进
   `xnu/patches/series.songyuan`（必须排在 `0103-songyuan-machine-config-4k` 之后）
2. 推 CI，`MACHINE_CONFIG=SONGYUAN`
3. 下载 `kernel.development.songyuan` → `mkpayload` → `loader` → QEMU 跑 8 秒
4. QMP `pmemsave <boot_args PA> 0x1000`，读 `0x700..0x720`

> 注意：本文件是**草案**，不在 `series.songyuan` 里。加进去会改变内核行为，
> 诊断完成后应移除。
