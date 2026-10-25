# songyuan 移植仓库（骨架）

K100 Pro Max（`songyuan` / SM8850 / CANOE）的 XNU 移植工程。
**本目录是从 [`data-a-live`](https://github.com/ShueiTsuki/data-a-live)（小米 17 Pro / pandora）
复制出的基线骨架**，已按本机实测参数补充。

## 为什么以 data-a-live 为基线

| 依据 | songyuan | pandora |
|---|---|---|
| SoC | SM8850 / CANOE | 同 |
| `qcom,chipid` | `0x44050A01` | `0x44050A01` |
| `gpu_model` | `Adreno840v2` | Adreno 840 v2 |
| GMU | `0x03D37000 +0x68000` | 同 |
| 启动方式 | `fastboot boot`（不写分区） | 同 |
| 目标系统 | iPhone X / iOS 16.7.16 | 同 |

四条硬件证据一致，所以直接沿用它的驱动与启动方式，只改板级参数。

## 目录

| 路径 | 内容 | 状态 |
|---|---|---|
| `wsl/songyuan_board.h` | **本机实测常量**（chipid/GPU/GMU/SMMU/splash/面板） | ✅ 已填 |
| `wsl/pandora_gpu.c` | pandora 的 Adreno 840 驱动（3206 行）；编译开关已扩到 `SONGYUAN`，常量统一走 `songyuan_board.h` | 🟡 已接开关 |
| `wsl/PandoraAdrenoGpu.cpp` | C++ 侧封装 | 📋 基线 |
| `wsl/adreno/` | ArmSmmu4K、NativeAdrenoABI 等 | 📋 基线 |
| `xnu/patches/` | 197 个内核补丁（ios-sweet / pandora 系列） | 📋 基线 |
| `tools/mkadt_pandora.py` | ADT 生成，需改名为 songyuan | 📋 待改 |
| `tools/boot_ios.sh` | 启动镜像组装与 `fastboot boot` | 📋 待改 |
| `.github/workflows/xnu.yml` | 内核 CI（macos-14 编 xnu-8796） | 📋 待改 machine_config |
| `docs/` | 移植文档 | 📋 待写 |

## 首次可用的判据（按顺序）

1. `fastboot boot` 我们的镜像，屏幕出字 —— **✅ 已达成**（见 `../../FIRST_BOOT.md`）
2. 解析设备树取到 chipid —— **✅ 已达成**（`0x44050A01`）
3. GPU 上电 → GMU 冷启动 → HFI 就绪
4. GPU SMMU 接管 → CP 初始化 → 命令缓冲可执行
5. 显存池 + 用户接口（NativeAdreno ABI）
6. Vulkan / Metal 出图

## 已知风险

- **看门狗**：ABL 交接后约 10–15 秒触发复位，长实验必须自备"续命"手段或分段验证
- **帧缓冲越界**：声明 11 MiB，一帧需 12.8 MiB，已实测越界写仍工作（未定义行为）
- **SMMU 长度**：本机 `0x40000`，pandora `0x20000`，不能照抄
- **PAC**：EL1 视角无 PAC；Android 侧有 `paca/pacg`，推断为 EL2 注入

详细数据见 [`PLATFORM_FACTS.md`](../../PLATFORM_FACTS.md) 与
[`GPU_INTEGRATION.md`](../../reference/GPU_INTEGRATION.md)。
