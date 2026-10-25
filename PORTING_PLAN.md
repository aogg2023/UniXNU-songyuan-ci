# songyuan 移植计划

基线：`data-a-live`（pandora）。本机参数：见 `wsl/songyuan_board.h`。
本文件只写"要做什么、怎么验收"，不写宣传语。

## 0. 现状

| 能力 | 状态 |
|---|---|
| `fastboot boot` 自编译镜像 | ✅ 已上真机 |
| 设备树解析（chipid / GMU / SMMU / splash / 面板） | ✅ 已取到 |
| 显示几何（1200×2668，stride 4800） | ✅ 已标定 |
| GPU 身份（`0x44050A01`，与 pandora 同款） | ✅ 已确认 |
| 内核编译链路 | ⛔ 未搭（需 CI 或 Linux 工具链） |
| GPU 驱动移植 | ⛔ 未开始 |

## 1. 离线可做（不碰设备）

### 1.1 编译开关

`wsl/pandora_gpu.c` 使用 `#if defined(PANDORA)` 包住整段实现（236 处 `pandora` 符号）。
第一步只扩开关、不改符号名，把 diff 压到最小：

```c
#if defined(PANDORA) || defined(SONGYUAN)
```

`PandoraAdrenoGpu.cpp`（80 处 `Pandora`）同理。符号名暂不重命名——重命名留到
驱动能跑之后，避免"改名 + 改逻辑"混在一起无法二分。

### 1.2 固件名核对

驱动引用 `gen80200_gmu.bin`、`gen80200_sqe.fw`、`gen80200_zap.mbn`。
`gen80200` 对应 **gen8.2**，与 chipid `0x44050A01` 的编码一致，**预期相同**，但必须核实：

- 有 root 时：`ls /vendor/firmware/gen80*`
- 无 root：从 `vendor_boot` 分区或厂商固件包取
- 判据：名字与长度都要对上，否则 GMU 起不来

### 1.3 ADT 参数

| 参数 | songyuan 值 | 来源 |
|---|---|---|
| DRAM 大小 | 0x10000000（示例，需按实际） | DT `/memory` |
| CPU regs | 2+6，capacity 1024 / 762 | 实测 |
| `psci_method` | `smc` | 与 pandora 相同（待 hello 复核 `/psci`） |
| splash | `0xFC800000` | DT |
| 面板 | 1200×2668 | DT |

`tools/mkadt_pandora.py` 复制为 `mkadt_songyuan.py` 后按上表改。

### 1.4 启动脚本

`tools/boot_ios.sh` 里的设备名、分区名、镜像参数需要按 songyuan 调整：
- `fastboot boot` 的目标序列号：`a928b15f`
- boot 镜像 header：**v4**（已验证）
- 镜像大小上限：注意 ABL 的 `Load Error` 阈值（nabu 记录为约 34 MiB，仅供参考）

## 2. 需设备的分级验证（照 pandora 的 15 级）

| 级 | 目标 | 验收 | 前置 |
|---|---|---|---|
| 1–3 | GPUCC 供电/时钟、GMU 状态 | 读到 `CX` 开、GMU 复位、24 个 SMR 空闲 | 无 |
| 4 | GMU 自己的 SMMU 上下文 | 读回配置一致并可 enable | 1–3 |
| 5 | GMU 冷启动（固件载入 ITCM/DTCM） | `FW_INIT_RESULT 0x100`、HFI ready | 4 + 固件核对 |
| 6–7 | 频率/带宽投票 | GMU 回 ack，error 0 | 5 + OPP 表 |
| 8–10 | GPU SMMU + CP + zap | ring 建立、SQE 载入、zap 通过 | 6 |
| 11–13 | 显存池 + 用户接口 | NativeAdreno ABI 可用 | 8–10 |
| 14–15 | GPU 合成 | 屏幕上由 GPU 画出一帧 | 11–13 |

**每一级都必须能在屏幕上留下可辨认的标记**（数字/颜色），因为看门狗只给 10–15 秒。

## 3. 不能照抄 pandora 的地方

| 项 | pandora | songyuan | 处理 |
|---|---|---|---|
| SMMU 长度 | `0x20000` | **`0x40000`** | 按实际长度映射，不要写死 |
| splash 长度 | `0x2b00000` | **`0xB00000`**（且一帧需 12.8 MiB > 11 MiB） | 绘制范围按实测裁剪 |
| 面板 | 1220×2656 | **1200×2668，stride 4800** | 全部替换 |
| PAC | — | EL1 视角 APA/API/GPA/GPI 全 0 | 不要启用 PAC 相关路径 |
| 16 KiB 页 | 无 | 无（TGran16=0） | 4 KiB 补丁必须全上 |

## 4. 门控（沿用本机已有工具）

1. 所有镜像先过 `mkbootimg_v4.py`，用 `bootimg_info.py` 核对头部
2. 任何 `fastboot` 命令走白名单（`tools/../lib/SafetyGuard.ps1` 的等价物）
3. 每次真机实验后立刻 `fastboot reboot` 或等待看门狗复位，不做"挂着不管"

## 5. 下一步（本周）

1. 把 `#if defined(PANDORA)` 扩到 `SONGYUAN`，先让 CI 能编出 `SONGYUAN` 内核
2. hello v6：dump `gpu-opp-table` 与 `/psci`，补齐 1.3 的空白
3. 核 `gen80200_*` 固件名
4. 按 1–5 级逐级点亮 GPU

---

## 6. 补丁移植量实测（2026-10-25）

对 `xnu/patches/` 的 197 个补丁做了硬编码扫描，结论比预期乐观得多：

| 检查项 | 结果 |
|---|---|
| 名字含 `pandora` | 94 个 |
| 名字含 `sweet`/`fuxi` | 99 个 |
| 硬编码 splash 地址 `0xfc800000` | **0 个**（运行时从 DT 取） |
| 硬编码 GMU 地址 `0x3d37000` | **0 个**（同上） |
| 硬编码 chipid `0x44050a01` | 4 个（0166 / 0177 / 0182 / 0187） |
| 硬编码 SMMU 基址 `0x3da0000` | 1 个（0096，fuxi） |

### 结论

- **splash 与 GMU 地址根本不写死在补丁里**，全部从设备树运行时读取 → 移植时无需改
- **chipid 与 songyuan 实测值逐位相同**（`0x44050A01`）→ 那 4 个补丁无需改
- **SMMU 基址相同**（只是长度不同，而补丁里只有基址）→ 无需改

**即：197 个补丁可以原样使用，不需要补丁手术。**

真正的移植工作集中在三处：
1. `machine_config` 增加 `SONGYUAN`（已做）
2. ADT / DTS 参数（DRAM、CPU regs、面板、psci）
3. 驱动里的板级常量（`songyuan_board.h`，已填）

这是今天最有价值的一条：它把"移植"从"改内核代码"降级成"填参数表"。
---

## 7. 内核构建链路：已实证打通（2026-10-25）

### 7.1 补丁可应用性

对 **xnu-8796.141.3**（Darwin 22.6.0）实测：**196 个补丁全部干净应用**。

```
基线:  tar xzf xnu-8796.141.3.tar.gz
前置:  模拟 0026-stage-hfs.sh（拉 Apple HFS @31d5ec2，铺到 bsd/sweet_hfs/）
序列:  xnu/patches/series.songyuan（196 行）
结果:  成功 196 / 失败 0
```

> 早先"2 个补丁失败"是假象：`0031` / `0041` 依赖 HFS staging，而我在 Linux 上没跑
> 那个脚本。staging 之后两者都干净通过。

### 7.2 SONGYUAN 机型是如何注册的

关键发现：`ARM64_BOARD_CONFIG_SWEET` 不是头文件里的 `#define`，而是**由
`makedefs/MakeInc.def` 的 `MACHINE_FLAGS_ARM64_*` 传进去的**。pandora 就是这么做的：

```make
MACHINE_FLAGS_ARM64_PANDORA = -DARM64_BOARD_CONFIG_SWEET -DFUXI=1 -DPANDORA=1 -march=armv8.2-a+crypto
```

我们的 `0103-songyuan-machine-config-4k.patch` 做同样的事，并多做两点：

```make
MACHINE_FLAGS_ARM64_SONGYUAN = -DARM64_BOARD_CONFIG_SWEET -DFUXI=1 -DPANDORA=1 -DSONGYUAN=1 \
                               -DXNU_NATIVE_CS_HASH_CACHE=1 -march=armv8.2-a+crypto
```

- 保留 `-DPANDORA=1`：复用 pandora 已调好的 GPU/ADSP/显示代码路径（同 SoC）
- 并入 `-DXNU_NATIVE_CS_HASH_CACHE=1`：4 KiB 签名哈希缓存（pandora 是在 0124 里单独加的）

### 7.3 与 pandora 序列的差异（仅两处）

| 补丁 | 处理 | 原因 |
|---|---|---|
| `0102-pandora-machine-config-4k.patch` | **剔除** | 注册的是 PANDORA；由 0103 取代 |
| `0124-pandora-native-4k-cs-hash-cache-on.patch` | **剔除** | 只给 PANDORA 的 flags 行加开关；已并入 0103 |

两者都改 `makedefs/MakeInc.def` 的同一批行，与 0103 冲突，不能共存。

### 7.4 构建前提清单

| 要求 | 状态 |
|---|---|
| 宿主 | macOS + Xcode 15（iig ABI 匹配 xnu-8796）或 GitHub Actions `macos-14` |
| `MACHINE_CONFIG` | `SONGYUAN` |
| 补丁序列 | `xnu/patches/series.songyuan` |
| HFS staging | `0026-stage-hfs.sh`（要求 `MACOS_VERSION=13.5`） |
| 4 KiB 页 | `__ARM64_PMAP_SUBPAGE_L1__`，且不进 arm64e 路径 |

### 7.5 仍未验证的部分

- 实际编译（本机没有 macOS，也未接入 CI 仓库）
- 编译产物与 pandora 的 ABI 是否一致（`native-4k-signature-hash-cache` 已应用，但需链接期确认）
- GPU OPP 表（DT 里没有，需驱动侧补；不阻塞 1–5 级上电）
---

## 8. Linux 构建实证（2026-10-25，无 macOS）

### 8.1 工具链已建成

用 UniXNU 的 `scripts/linux/setup-toolchain.py` 从源码构建，**全部成功**：

| 组件 | 结果 |
|---|---|
| clang 24.0.0git（含 `__builtin_xnu_type_*`） | ✅ 从 pinned LLVM 源码编译 |
| cctools-port ld64 956.6（`ld/nnm/lipo/ar/strip`） | ✅ 可链接 Mach-O |
| `mig` / `iig` / `migcom` | ✅ |
| `xcrun` / `plutil` / `codesign` 替身、`xnu-host-cc`、`lzfse` | ✅ |
| libdispatch（swift-6.4.0-RELEASE）+ libBlocksRuntime | ✅（cctools 与 firehose 都依赖） |

**验证**：`clang -target arm64-apple-ios17.0 -mkernel -nostdinc -c` 输出
`Mach-O 64-bit arm64 object` —— Linux 上能产 Apple 目标文件。

### 8.2 构建驱动 `tools/build_xnu_linux.sh`

五步全部打通，每一步都踩过坑并解决：

| 步 | 内容 | 踩过的坑 |
|---|---|---|
| 0 | availability.pl + 脚本适配 | XNU 硬拼 `SDKROOT/.../availability.pl`；改为 `XNU_AVAILABILITY_PL` 出口 |
| 1 | 铺 fakeroot 头 | 缺 `TargetConditionals.h`（iPhoneOS SDK 专有）；`os/` 子目录要整棵拷 |
| 2 | `make installhdrs` | 无 `sysctl`/`sw_vers` → 用命令行变量覆盖（`SYSCTL_HW_*`、`MEMORY_SIZE`、`HOST_OS_VERSION`、`PLATFORM`） |
| 3 | `libfirehose_kernel.a` | `<internal/atomic.h>` 指向 libdispatch 的 `src/shims/atomic.h` |
| 4 | `libcc_kext.a` | `prepare-xnu.py` 要联网拉 llvm-project；本地已有 → 加 `fetch()` 短路 |
| 5 | 内核 `make` | **当前卡点** |

### 8.3 当前卡点：clang 24 vs Apple clang 的 C++ 兼容性

编译进度：**343 个编译单元完成**（含我们补丁里的 `sweet_pthread_init.o`），
总计 **30 个错误，集中在 3 个文件**：

| 文件 | 错误 |
|---|---|
| `iokit/IOKit/IOLib.h` | `indirection not permitted on operand of type 'void *'`（`IOOverrideTypedOperators` 宏） |
| `osfmk/vm/vm_compressor.c` | 同类（2 处） |
| `iokit/Kernel/IOUserServer.cpp` | 同类（2 处） |

原因：Apple clang 对 `IOTypedOperatorsMixin<T>` 里 `operator new/delete` 的模板化写法更宽松；
LLVM 24 收紧了对 `void *` 解引用的检查。

修法（下一步）：按 UniXNU `prepare-xnu.py` 的做法，用
`__apple_build_version__` / `__has_feature` 守卫这些宏，让非 Apple clang 走等价路径。
这属于**源码兼容性补丁**，不是架构问题。

### 8.4 结论

- **不需要 macOS** 这一点已被实证：工具链、installhdrs、firehose、libcc_kext 全部在 Linux 上跑通
- 剩下的是 clang 版本兼容的长尾，与 UniXNU 当年遇到的是同一类问题
- CI 路线仍然更快（`macos-14` runner + 已就绪的 196 补丁序列）
---

## 9. CI 构建成功（2026-10-25，首个可运行内核）

仓库：`https://github.com/aogg2023/UniXNU-songyuan`（私有）
Run：**#1**，`success`，耗时 **4.4 分钟**（macos-14 / M 系列多核）

### 9.1 产物

| 文件 | 大小 | SHA256 |
|---|---|---|
| `kernel.development.songyuan` | 16.19 MB | `b9dab0407714b5253cfc0bc531f2ff17419e079ed80d2aee0a44045baf65596f` |
| `xnu-buildtree` artifact | 22.7 MB | 含 fakeroot 头与打过补丁的源树 |
| `xnu-objects` artifact | 50.4 MB | 全部 .o + 链接脚本（供 `wsl/local_relink.sh` 用） |

### 9.2 内核身份验证

| 检查 | 结果 |
|---|---|
| 文件类型 | `Mach-O 64-bit arm64 executable, flags:<NOUNDEFS\|PIE>` |
| 版本串 | `Darwin Kernel Version 22.6.0 … xnu-8796.141.3` |
| 符号总数 | 71,531 |
| `_bsd_init` / `_kernproc` / `_pmap_bootstrap` | 存在（非桩） |
| `__TEXT` vmaddr | **`0xfffffe0007004000`** |
| 补丁痕迹 | `sweet_hfs` 17 处、`pandora_gpu` 35 处、`songyuan` 243 处 |

**4 KiB 页的直接证据**：4K 内核基址是 `0xfffffe0007004000`，
16K 内核会是 `0xfffffff007004000`。我们落在前者。

### 9.3 这一步证明了什么

- 196 个补丁在真实 macOS 工具链下**全部应用且编译通过**（`error:` 行数为 0）
- `0103-songyuan-machine-config-4k.patch` 生效：`SONGYUAN` 在日志出现 **59,813 次**
- `MACHINE_CONFIG=SONGYUAN` 走通 `makedefs` → `MASTER.arm64.songyuan` → 4K 页路径

### 9.4 CI 里发现并修掉的坑

`xnu.yml` 原本用 `cp xnu/patches/*.patch dxb/patches/`，而 blacktop 的 `build.sh`
会**全量应用**该目录下的补丁 → `0102`(pandora) 与 `0103`(songyuan) 改同一批行，必然冲突。
已改为按 `series.songyuan` 清单逐个复制，并加 `test "$n" -ge 190` 兜底。

### 9.5 下一步

1. 生成 ADT：`python3 tools/mkadt_songyuan.py out.adt`（DRAM 窗口仍是假设值）
2. 准备 payload / 引导链（参考 `tools/boot_ios.sh` 与 `wsl/` 的 shim 做法）
3. 真机 `fastboot boot` 验证内核能否跑到 `bsd_init`
---

## 10. 首次真机引导 XNU（2026-10-25）

### 10.1 引导链已全部打通

| 环节 | 结果 |
|---|---|
| ADT 生成（`tools/mkadt_songyuan.py`） | 18,976 字节，`compatible` 含 `xiaomi,songyuan` |
| payload 打包（`mkpayload.py`） | 16,373,792 字节，段表正确 |
| loader 编译（`shim/loader`，Linux clang） | 16.4 MB boot.img，header v4 |
| **真机 `fastboot boot`** | **loader 全部安检通过并跳入内核** |

真机屏幕实测（loader 自检结果）：

```
LEVEL     EL1
LOADED    0x00000000C7800000
PAYLOAD   0x00000000C780B000
PHYS      0x00000008C0000000      ← 我们的 DRAM 假设，被真正使用
MEMSIZE   0x000000013FF00000
ENTRY     0xFFFFFE000741E488      ← 4 KiB 内核入口
KERN_END  0x00000008C29C4000
BOOTARGS  0x00000008C29C9000
JUMP      0x00000008C141E488
XNU       jumping (the kernel console takes over)
```

**结论：引导链（ADT→payload→loader→跳转）完全正确，DRAM 窗口假设成立。**

### 10.2 内核卡点：`_arm_init` 取指异常

QEMU 复现（`tools/qemu_loader.py` + 串口补丁）给出确切位置：

```
Prefetch Abort, ESR 0x86000004 (level-0 translation fault)
FAR = ELR = 0xfffffe0007ab3488  →  符号 _arm_init (+0)
```

已排除的可能：
- 不是段拷贝问题：物理地址 `0x51AB3488` 读出的是正确 ARM64 代码
  （`0xd10343ff sub sp,sp,#0xd0` …）
- 不是段越界：`__TEXT_EXEC` 覆盖 `0x7270000..0x7b18000`，`arm_init` 在其中
- 不是 loader 问题：loader 自检全过并成功跳转

**结论：控制流到达 `_arm_init` 时，该页尚无有效映射（L0 项无效）。**
这是 XNU arm64 在 4 KiB granule 下的早期映射问题，需要在
`arm_vm_init` / `pmap_bootstrap` / `start.s` 里查映射覆盖范围。

### 10.3 新增的调试能力（可复用）

| 工具 | 作用 |
|---|---|
| `loader.c` 的 `QEMU_SERIAL` | 把 loader 的每条日志同时写到 PL011（0x09000000） |
| `build.sh` 的 `QEMU=1` | 串口输出 + QEMU 的 RAM 范围（真机不编这段） |
| `mkadt_songyuan.py` 的 `SONGYUAN_DRAM_BASE/SIZE` | 把 DRAM 窗口搬进 QEMU virt RAM |
| `qemu_loader.py`（已调几何） | 1200×2668 帧缓冲解码 + 寄存器/物理内存转储 |

**这套能力让"改一次 → 上真机拍屏"变成了"本地 20 秒一轮"。**

### 10.4 参考对照的坑

从 data-a-live CI 下载的 `kernel.development.pandora` 入口是
`0xFFFFFFF007406488`——那是 **16 KiB 基址**，不是 4K。
所以该 artifact 不能直接作为 4K 对照，A/B 需要同版本的 4K 构建。

### 10.5 下一步

1. 读 `osfmk/arm64/start.s` + `osfmk/arm/arm_init.c` + `pmap_bootstrap`，
   确认 4K 配置下早期映射的结束地址如何计算
2. 检查 `__ARM64_PMAP_SUBPAGE_L1__` 是否真的生效（`SWEET.h` 里 `defined(PANDORA) || defined(SONGYUAN)` 分支）
3. 必要时在 CI 里加一个 `PANDORA` 的 4K 对照构建（同一套补丁、不同 machine config）
### 10.6 已排除项与剩余假设（2026-10-25 收尾）

**已排除**

| 假设 | 证据 |
|---|---|
| 段拷贝错误 | 物理 `0x51AB3488` 读出正确 ARM64 代码（`sub sp,sp,#0xd0` …） |
| 段越界 | `__TEXT_EXEC` 覆盖 `0x7270000..0x7b18000`，`arm_init` 在段内 |
| bootstrap 表容量 | 4K 下 `BOOTSTRAP_TABLE_SIZE = 16 页`，5 GiB 窗口需 12 页（2 根 + 10 L2），够 |
| loader 逻辑 | 自检全过，`JUMP` 地址与内核入口一致 |
| ADT/payload 打包 | `mkpayload` 段表与内核 `otool -l` 完全一致 |

**剩余假设（按优先级）**

1. **`arm_init` 的调用目标没被 KVA 映射覆盖**
   - `start.s` 用 `create_bootstrap_mapping` 建 V=P 和 KVA 两套映射，
     范围由 `boot_args.memSize`（即 `x24`）决定
   - 我们传的是 5 GiB；若 KVA 侧 L1 索引计算与实际 VA 不一致，
     就会出现"同段内一部分可执行、另一部分 L0 无效"的现象
2. **`virt_base` 对齐假设**
   - `mkpayload` 的 `virt_base = text.vmaddr & ~(0x2000000-1)` = `0xfffffe0006000000`
   - start.s 的 KVA 映射可能假设 `virt_base` 与 `phys_base` 的 2 MB offset 相同
3. **`_start` 里 `x26 bootFlags` 的取值**（我们没设 `bootFlags`，为 0）

**下一步实验（成本从低到高）**

1. QEMU 里 dump `TTBR1_EL1` 与 L0/L1 表内容，直接比对 `arm_init` 的 VA 索引是否有项
2. 在 start.s 里 `bl arm_init` 之前加一个 `sweet_early_mark`（该机制已存在，stage 1 就在
   `arm_init` 第一行）——若能打出 stage 0 而没 stage 1，即确认"调用前失败"
3. 用 QEMU 的 `-d in_asm` 从入口单步，看第一条取指失败的指令

**命名冲突提醒**：补丁集里 `0103` 有两个（`0103-songyuan-machine-config-4k` 与
`0103-unixnu-native-4k-bootstrap-capacity`），排序后 songyuan 在前、unixnu 在后，
应用顺序正常，但阅读时容易混。
### 10.7 页表实测：映射存在，问题更深（2026-10-25）

用 QMP `pmemsave` 在崩溃态 dump 了 bootstrap 页表池（`0x51186000`，16 页）：

```
V=P L1[1] → L2@0x51188000  项 136..511   (0x51000000..0x7FE00000)
V=P L1[2] → L2@0x51189000  项 0..126     (0x80000000..0x8FC00000)
KVA L1[0] → L2@0x5118a000  项 56..511    (0x51000000..0x89E00000)
KVA L1[1] → L2@0x5118b000  项 0..46      (0x8A000000..0x8FC00000)
```

关键换算：KVA 的 `L2[61]` = `0x51A00601`（2 MB 块），覆盖
`0x51A00000–0x51BFFFFF`；而 `arm_init` 的物理地址 `0x51AB3488` 正在其中。

**结论：bootstrap 页表确实映射了 `arm_init`。**
"映射缺失"假设被推翻，Prefetch Abort（ESR DFSC=0x4，L0 翻译错误）另有原因。

剩余可能（按优先级）：

1. **TTBR1 指向的不是这张表**——`x3 = x25 + PGBYTES` 只是我们推断的 KVA 根，
   实际 `TTBR1_EL1` 可能被别处改写，或 slide 后重定向到别的页
2. **TCR_EL1 的 T1SZ 不覆盖该 VA**——若 T1SZ 偏小，`0xfffffe00_xxxxxxxx`
   超出可译址范围，walker 在第 0 级就判无效（正好对应 DFSC=0x4）
3. 表项属性缺位（但我们 dump 到的项含 `0x601` = valid|AF|…，看起来正常）

**下一步必须拿到 `TTBR1_EL1` 与 `TCR_EL1` 的实际值**，手段：
- QEMU gdbstub（`-s`）连 gdb-multiarch，`info registers` 读系统寄存器
- 或在 `start.s` 里紧跟 `MSR_TTBR1_EL1_X0` 之后把寄存器写到串口/FB

### 10.8 发现一个真实的移植 bug（尚未修）

`osfmk/arm64/start.s` 的早期调试标记写死了 **SWEET 的帧缓冲**：

```asm
#if defined(SWEET) && !defined(FUXI)
    /* Stage 0: white 64x32 band, no stack or page tables needed. */
    MOV64 x0, (0x9c000000 + 2368 * 4320)
    ...写 64x32 像素...
#endif
```

我们定义了 `SWEET`（经 `ARM64_BOARD_CONFIG_SWEET`）而未定义 `FUXI`，
所以这段会编译进来，往 `0xC30A4C00` 写 8 KB 白块——那在本机是任意一段 RAM。

修法：把条件改成 `#if defined(SWEET) && !defined(FUXI) && !defined(SONGYUAN)`，
或把地址/几何改成从 `boot_args.Video` 读（更正确，但 MMU 未开时需用物理地址）。
---

## 11. 根因与修复：KVA 不可译（2026-10-25）

### 11.1 症状

内核跳到 `arm_init` 即 Prefetch Abort（`DFSC=0x4`，第 0 级翻译错误），
随后在异常向量处自循环。真机与 QEMU 表现一致。

### 11.2 定位过程（每一步都有可复现的证据）

| 步骤 | 结论 |
|---|---|
| 物理内存 dump | `arm_init` 的代码在物理内存里是正确的，排除段拷贝问题 |
| bootstrap 页表 dump（QMP `pmemsave`） | KVA `L2[61] = 0x51A00601` 覆盖 `arm_init` 的 PA，**映射存在**，排除"没映射" |
| 内核内 diag（写魔数+寄存器到 boot_args 页） | 第一次 Data Abort：`FAR = boot_args VA`、`ELR` 是**物理地址** → 说明在 V=P 窗口写入 KVA 失败 |
| 读回 `TCR_EL1 = 0x22a51a251a` | `T1SZ=26`（38 位 VA），而内核链在 `0xfffffe00_...`（**41 位**） |

**关键计算**：`0xfffffe00_089c96f0 >> 38 = 0x3FFFFF8 ≠ 0x3FFFFFF` → 该地址不可能被翻译。

### 11.3 根因

`makedefs/MakeInc.def`：

```make
ifneq ($(filter $(PLATFORM),MacOSX),)
ifeq ($(filter PANDORA,$(CURRENT_MACHINE_CONFIG)),)   # 只豁免了 PANDORA
LARGE_MEMORY_DEFINE=-DARM_LARGE_MEMORY=1
ARM64_LINK_ADDR    =0xfffffe0007004000                 # 41 位布局
endif
endif
```

SONGYUAN 继承了 `ARM_LARGE_MEMORY`，内核链到 `0xfffffe00_07004000`，
而 `TCR_EL1_BOOT` 的 `T1SZ_BOOT` 在 4 KiB 配置下是 26（38 位）——
**"4K 页 + ARM_LARGE_MEMORY" 这个组合 XNU 不支持**（`proc_reg.h` 注释：
4K 满页 L1 是 39 位、子页 L1 是 38 位）。

pandora 之所以没踩到：它的参考内核入口是 `0xfffffff0_07406488`（32 位前缀），
本来就落在 38 位范围内。

### 11.4 修复

`0199-songyuan-ios-va-layout.patch`：把 SONGYUAN 加入豁免名单。

```make
ifeq ($(filter PANDORA SONGYUAN,$(CURRENT_MACHINE_CONFIG)),)
```

> 必须让这个补丁**排在所有补丁之后**（命名 `0199-`）：数据里有另一个补丁会
> 整体重写 `MakeInc.def`，早期应用会被覆盖/冲突。已验证 CI 顺序下 198/198 全部干净应用。

### 11.5 修复后的实测

| 项 | 值 |
|---|---|
| `__TEXT` vmaddr | `0xfffffff007004000`（iOS 布局） |
| diag 魔数 | `0x534f4e4759554e01` 写入成功（代码执行到） |
| `TTBR0_EL1` / `TTBR1_EL1` | `0x51186000` / `0x51187000` |
| `TCR_EL1` | `T0SZ=26 T1SZ=26 TG0=0(4K) TG1=2(4K)` |
| `SCTLR_EL1.M` | 1（MMU 开） |
| `ID_AA64MMFR0_EL1` | `0x1124`（TGran16=0，PARange=44 位） |
| 真机 | **内核控制台打印了启动日志**，随后切到黑屏 + 底部蓝条 |
| QEMU | 复现同一画面，PC 停在 `_halt_all_cpus + 0x34` |

### 11.6 顺带修掉的 QEMU 陷阱

`qemu_loader.py` 默认 `-cpu cortex-a76`（ARMv8.0 级别），
不支持我们用 `-march=armv8.2-a+crypto` 编出的 LSE 原子指令，
会产生**假的 `Undefined Instruction`**（`_lck_grp_reference` 等）。
**必须用 `-cpu max`**，否则诊断会被误导。

### 11.7 下一步

1. 拿到那屏内核日志的内容（真机抢拍 / 连拍 / 慢动作）
2. 或在 QEMU 里让内核控制台走 PL011，这样 `serial.txt` 就能直接拿到 panic 文本
   （`sweet_early` 已有输出钩子，加一个 QEMU 目标即可）
3. 栈回溯需要按段分别换算 PA（内核栈不在线性映射区），或直接用 gdbstub
### 11.8 修复后的执行位置（2026-10-25 续）

用 gdbstub 跟踪 `kprintf`，抓到内核实际打印的头两条：

```
vm_cache_geometry_colors: %d
%s() - %u bytes %s cache (I:%u D:%u (%s)), %u-way assoc, %u bytes/line
```

说明内核已进入 **VM/缓存几何初始化**，随后 `panic()` → `halt_all_cpus(TRUE)`
（`osfmk/kern/debug.c:1179`）。PC 采样显示 0.4 秒内就停住。

**为什么屏幕看不到 panic 文本**：本机控制台走 SM8850 的 UART/显示路径，
QEMU virt 里没有对应的 UART；帧缓冲控制台在 panic 前被显示驱动清屏。

### 11.9 抓 panic 文本的三条路（按可靠性排序）

1. **让 kprintf 同时写 PL011**（最稳）：加一个只在 `XNU_QEMU_SERIAL` 编译时生效的钩子，
   把 kprintf 的输出写到 `0x09000000`。之后 QEMU 的 `serial.txt` 就是完整内核日志。
   代价：一次 CI（现在约 5 分钟）+ 6 MB 下载（约 2 分钟）
2. gdbstub 跟踪 kprintf：已能抓到前两条，但批量循环不稳定
   （`commands`/Python 断点在连续命中时会失步）
3. 真机抢拍：文字存在时间太短，且会被显示驱动清屏，不可靠

### 11.10 当前状态一句话

**内核已能在正确 MMU 配置下启动并进入 VM 初始化**，之后 panic；
下一步是把内核日志接出来看 panic 原因。
### 11.11 panic 文本已拿到（2026-10-25 晚）

借助 HackiOS 项目的思路（`pe_kprintf` 挂 `loader_log_putc`），我们确认**自己的补丁集里本来就有日志环**：
`bsd/dev/sweet_ufs.c` 的 `sweet_log_ring[4 MiB]` + `sweet_log_total`，由 `_cnputs()` 写入。
dump 环缓冲（`0x51CA2948`，按 `total % SIZE` 旋转）后读到：

```
MACH Reboot
```

——只有 12 字节，说明内核在开 verbose 前就死了，**屏幕/串口注定拿不到信息**。

### 11.12 用 gdbstub 逐层剥开 panic

| 断点 | 读到的内容 | 含义 |
|---|---|---|
| `panic_trap_to_debugger` | va_list 里 `"Invalid kernel stack pointer (probable corruption)."` | 这是 **check_exception_stack** 抛的二次 panic |
| 异常向量入口 `el1_sp1_synchronous_vector_long` | `SP = _excepstack+0x39f0`（合法异常栈），`LR = DebuggerTrapWithState+0x48` | 故障发生在 **panic/debugger 路径内部**，即二次故障 |
| `_panic`（正确地址 `0xfffffff007a71e2c`） | `x0` = 通用 trap 格式串；`x3 = 0x9600004f604003c4` | 高 32 位 `0x9600004f` = **Data Abort 的 ESR**（EC=0x25），低 32 位是 PSTATE |
| 同上 | `x1 = 0xfffffff007359e3c` → `vm_fault_internal+0x20` | 首次故障发生在 **`vm_fault_internal`** |

**正确的根因链（三层）**：

1. `vm_fault_internal` 里发生 Data Abort（ESR `0x9600004f`）
2. 进入 trap 后的调试/打印路径再次出错 → 异常发生在 `DebuggerTrapWithState`
3. `check_exception_stack` 判定栈异常 → panic `"Invalid kernel stack pointer"` → `halt_all_cpus`

所以屏幕上看不到任何 panic 文本是**必然**的：真正的消息在第 1 层，而第 2 层就崩了。

### 11.13 下一步（唯一正确入口）

在 `fleh_dispatch64`（`0xfffffff00740b41c`）下断点——异常帧（ESR/FAR/ELR + x0..x30）是它的参数，
dump 该帧即可拿到**第 1 次故障的 FAR/ELR**，也就是出错的确切地址。

> 注意：QEMU 8.2 的 gdbstub **不暴露** AArch64 系统寄存器（`p $esr_el1` 返回 void），
> 只能通过异常帧或 `-d int` 日志获取。

### 11.14 从 HackiOS 项目得到的其它结论

| 他们的做法 | 我们的对应 |
|---|---|
| `MACHINE_CONFIG=BCM2837`（XNU 原生 4K） | 我们用 `0199-songyuan-ios-va-layout.patch` 达到等效（切回 32 位前缀布局） |
| Linux + stock clang + theos cctools，无需 Xcode | 与我们自建的 Linux 工具链一致，路线可复用 |
| `qemu/where.py` + `sym.py` 在线符号化 | 可直接借用（我们目前用 nm + 手算） |
| DPU / Adreno 660 / Wi-Fi 补丁 | 硅不同（840 vs 660），暂不移植，显示部分可参考 `docs/LEMONADE-DISPLAY.md` |
### 11.15 真正的根因：`fbcon_init` 在 pmap 就绪前映射帧缓冲

`-d int` 抓到的**第一条异常**（`-cpu max`）：

```
Taking exception 4 [Data Abort] on CPU 0
...with ESR 0x25/0x96000047        EC=0x25 (同 EL 数据中止), WnR=1 (写), DFSC=0x7 (L3 翻译错误)
...with FAR 0xfffffff04d300000     要写的地址：无效
...with ELR 0xfffffff007a486c8     → _fbcon_init+0xb4
```

`_fbcon_init+0xb4` 对应 `pexpert/arm/pe_serial.c` 里 `fbcon_clear_row()`
写 `fbcon_base` 的第一条语句。而：

```c
fbcon_base = (volatile uint32_t *)ml_io_map_wcomb(reg[0], reg[1]);   /* pe_serial.c:861 */
```

`fbcon_init` 由 `PE_init_kprintf` 以 `STARTUP_RANK_FIRST` 调用，
**此时 `pmap_bootstrap` 还没执行**（它在 `arm_init → arm_vm_init` 里），
`ml_io_map_wcomb()` 返回的 VA 没有对应的页表项 → 写入即中止。

**完整因果链**：

1. 内核实现在极早期初始化控制台
2. `ml_io_map_wcomb()` 在 pmap 未就绪时返回无效 VA
3. `fbcon_clear_row()` 写该地址 → 数据中止（FAR `0xfffffff04d300000`）
4. 异常进入 trap 路径，调试/打印代码再次出错（`DebuggerTrapWithState`）
5. `check_exception_stack` 判栈异常 → `"Invalid kernel stack pointer"` → `halt_all_cpus`

→ **控制台自身是最先崩的那一环，所以屏幕上永远没有日志。**

### 11.16 修复方向（按可行性）

| 方案 | 说明 | 代价 |
|---|---|---|
| A. 推迟 fbcon | 把帧缓冲控制台初始化从 `STARTUP_RANK_FIRST` 挪到 pmap 就绪之后 | 一个补丁，需确认 XNU 启动秩 |
| B. 先线性映射 FB | 让 ADT 的 framebuffer `reg` 落在 bootstrap 覆盖的 DRAM 窗口内（需硬件 FB 可分页，不现实） | 不可行 |
| C. 失败即降级 | `ml_io_map_wcomb` 返回后先验证可写，失败则跳过 fbcon（退回串口） | 能启动但无屏，只适合配合 QEMU trace |
| D. loader 预先建映射 | loader 在 MMU 关闭时无法建映射 | 不可行 |

**推荐 A**：与 pandora 的差异可能就在启动秩/初始化顺序上。

### 11.17 复现命令（一次到位）

```sh
qemu-system-aarch64 -M virt,gic-version=3 -cpu max -smp 1 -m 4G -nographic \
  -serial file:serial.txt -monitor none -no-reboot -d int -D int.log \
  -kernel /tmp/qemu/loader/Image
grep -a -m1 -A5 "Taking exception" int.log
```

> 必须 `-cpu max`；`cortex-a57` 会先报假的 `Undefined Instruction`（缺 LSE 原子指令）。