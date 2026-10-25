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