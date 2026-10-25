/*
 * songyuan_board.h - K100 Pro Max (songyuan / SM8850 / CANOE) 板级常量
 *
 * 所有数值都来自真机实测，不是猜测。来源标注：
 *   [DT]    从 fastboot boot 的探针程序解析 x0 交付的设备树得到
 *   [SWEEP] 屏幕几何标定程序实测
 *   [PAND]  与 pandora（小米 17 Pro，同 chipid）对照
 *   [TODO]  待确认
 */
#ifndef SONGYUAN_BOARD_H
#define SONGYUAN_BOARD_H

/* ---- GPU ---- */
/* [DT] 与 pandora 的 0x44050a01 逐位相同 → 同一颗 Adreno 840 v2 硅片 */
#define SONGYUAN_CHIPID          0x44050A01u

/* [PAND] pandora 的 qcom,kgsl-3d0 reg；本机节点名不同，待 hello 复核 */
#define SONGYUAN_GPU_BASE        0x03D00000ull
#define SONGYUAN_GPU_SIZE        0x00040000u

/* [DT] GMU：与 pandora 完全一致 */
#define SONGYUAN_GMU_BASE        0x03D37000ull
#define SONGYUAN_GMU_SIZE        0x00068000u

/* [DT] GPU 的 SMMU：基址同 pandora，长度是它的两倍（0x40000 vs 0x20000） */
#define SONGYUAN_KGSL_SMMU_BASE  0x03DA0000ull
#define SONGYUAN_KGSL_SMMU_SIZE  0x00040000u

/* ---- 显示 ---- */
/* [DT] splash 基址与 pandora / 一加 infiniti 一致 */
#define SONGYUAN_SPLASH_BASE     0xFC800000ull
/* [DT] 声明 11 MiB。注意：1200x2668x4 = 12.8 MiB > 11 MiB，
 *      实测写到声明范围外 1.21 MiB 仍能正常显示，说明实际缓冲更大。
 *      这是已知未定义行为，见 PLATFORM_FACTS.md 第 10.2 节。 */
#define SONGYUAN_SPLASH_SIZE     0x00B00000u

/* [DT] 面板分辨率；[SWEEP] 步长由标定得出 */
#define SONGYUAN_PANEL_W         1200u
#define SONGYUAN_PANEL_H         2668u
#define SONGYUAN_PANEL_STRIDE    4800u    /* 1200 * 4 */

/* ---- 启动交接 ---- */
/* [实测] ABL 把镜像加载到该地址；x0 指向设备树 */
#define SONGYUAN_LOAD_ADDR       0xC7800000ull
#define SONGYUAN_FDT_ADDR        0xD5C31000ull   /* 每次启动可能不同，仅作参考 */

/* ---- CPU / 内存（XNU 侧需要）---- */
/* [实测] MMFR0 = 0x0210012210001024：16K 页不支持，4K/64K 支持，PA 44 位 */
#define SONGYUAN_HAS_16K_PAGES   0
#define SONGYUAN_HAS_4K_PAGES    1
#define SONGYUAN_PA_BITS         44

/* [实测] ISAR1 = 0x0010111100311002：EL1 视角下 APA/API/GPA/GPI 全为 0。
 * Android 的 /proc/cpuinfo 报 paca/pacg，推断为 EL2 注入，不代表硬件原生支持。 */
#define SONGYUAN_PAC_AT_EL1      0

#endif /* SONGYUAN_BOARD_H */
