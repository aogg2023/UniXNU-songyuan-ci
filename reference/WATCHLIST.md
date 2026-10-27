# 参考仓库观察清单（每天第一次先过一遍）

用途：每天开工先核对下面每个仓库的最新动向，判断有没有能直接整合的东西，避免重复造轮子。
更新方式：只改「最后一次核对」和「最新动向」两列；发现可整合项记到 §3。

## 1. 仓库列表

| 仓库 | 是什么 | 与我们的关系 |
|---|---|---|
| https://github.com/zg7681/myron-device | Redmi K90 Pro Max（myron, SM8850）设备仓库：board.toml、ADT 生成器、patches、scripts | **同平台**：状态、板级值、启动参数、镜像格式直接可对照 |
| https://github.com/zg7681/UniXNU-myron | `UniXNU/UniXNU` 的 myron fork（UEFI 路线） | 同平台的 XNU/补丁集，可对照 |
| https://github.com/zg7681/NativeUfs-myron | 原生 UFS 驱动：控制器/SMMU/队列/根读取，带日志窗口与 FUA 写窗口 | **直接对标我们卡住的根卷挂载与日志通道** |
| https://github.com/zg7681/NativeAdreno-myron | Adreno 840 GPU 驱动（XNU） | GPU 阶段可参考 |
| https://github.com/zg7681/AdrenoMetal | Metal → Vulkan（Turnip）桥 | GPU/Metal 阶段可参考 |
| https://github.com/zg7681/ArmCpu | ARM64 CPU / GIC / timer 驱动模块 | SMP/中断/定时器可参考 |
| https://github.com/UniXNU/UniXNU | 上游主项目（UEFI 引导 + 构建驱动 + 补丁） | 我们补丁的上游之一 |
| https://github.com/UniXNU/UniXNU-sheng | 小米平板 6S Pro（sheng）设备仓库 | 触控/Wi-Fi/GPU 已验证的参考实现 |
| https://github.com/oosexgang/hackios-xnu-kernel | HackiOS（A11 用户态在 XNU 上跑） | 用户态/SpringBoard 参考 |
| https://github.com/aogg2023/UniXNU-songyuan-ci | 我们的公开 CI 镜像 | 构建产物 |

## 2. 最近一次核对：2026-10-27

| 仓库 | 最新动向 |
|---|---|
| zg7681/myron-device | 10-26 12:20「the device repository as the tree boots today」、12:24「scan-out hand-off's stalled-frame rescue」、13:14「name the process a GPU connection was refused for」。README 状态：**iPadOS 17.7.11 跑到 SpringBoard**，触控 OK，Adreno 840 Metal（NativeMetal+Turnip）部分可用，UFS `unixnu` 分区做持久 Data，Wi-Fi/BT/USB/音频/摄像头未做。 |
| zg7681/UniXNU-myron | 最后提交 10-22（MobileGestalt 身份文档、GPU 双平面纹理）；fork 自 UniXNU/UniXNU。 |
| zg7681/NativeUfs-myron | 10-20：`sheng-log-reserve` 预留日志区、FUA 强写窗口、诊断日志窗口导出区；README：原生 UFS 根在 sheng 上可用。 |
| zg7681/NativeAdreno-myron | 10-22：GMU IFPC 关闭、导入页生命周期、GPU 对象上限 4096、metal 客户端与 render server 并存。 |
| zg7681/AdrenoMetal | 10-25 22:35：拒绝型 render encoder 返回、prime 列表跳过目录扫描、Turnip 逐 pass 选 tile/system 内存。 |
| zg7681/ArmCpu | 10-24 文档；10-20 导入。 |
| UniXNU/UniXNU | 10-26 18:35「docs: refresh device records」，1057 stars。 |
| UniXNU/UniXNU-sheng | 10-25 23:34「docs(porting): record the WiFi join and speed on sheng」——sheng 的 Wi-Fi 已通。 |
| oosexgang/hackios-xnu-kernel | 10-26 10:14 README 更新，1664 stars。 |

## 3. 可整合项（按对当前进度的价值排序）

1. **NativeUfs-myron 的根卷方式**：我们现在的根是「pinned file + extent 表」拼出来的 mock 块设备，
   真机上 `vfs_mountroot` 拿不到正常块设备语义（APFS 探测失败、HFS 报签名 0x6f2b、237 次重试）。
   他们的 NativeUfs 自己拥有控制器/SMMU/队列，把 GPT 分区当真正块设备给 XNU，并且有日志窗口
   （`sheng-log-reserve`）和 FUA 强写窗口。**这是同时解决「根卷挂载」和「持久日志」的路子。**
2. **SM8850 的 SMP/IPI 启动参数**（myron-device README 的 Known-good boot arguments）：
   `sheng-smp=1 armcpu-spi-ipi=1` + `myron-clear-sigp=1 myron-ipi-clearpend=1`（必须成对）。
   我们现在基本是 `cpus=1`；要开 8 核就要处理软件 SPI IPI 的 pending 位，否则核会风暴/发热。
3. **ADT/板级数据对照**：`board.toml`、`scripts/make-myron-adt.py`、`scripts/data/myron-observed.json`。
   他们的 splash 也是 `0xfc800000 + 0x2b00000`，和我们本轮修正一致；ADT 里其它节点（GPIO/regulator/
   power-domain/touch）可逐项对照我们缺什么。
4. **镜像格式**：他们明确写了「ramdisk 要用 header v0，v4 时 ABL 会从 init_boot 取通用 ramdisk」。
   我们 `mkbootimg_v4.py` 是 v4——以后要走 ramdisk 根必须换成 v0。
5. **GPU 全栈**（NativeAdreno-myron + AdrenoMetal + NativeMetal/Turnip）：等 UI 起来后再接，别提前。

## 4. 每天核对的命令

```powershell
$cred = "protocol=https`nhost=github.com`n`n" | git credential fill
$env:GH_TOKEN = (($cred -split "`n") | Where-Object { $_ -like 'password=*' }) -replace '^password=',''
$env:HTTP_PROXY=''; $env:HTTPS_PROXY=''
$gh='C:\Program Files\GitHub CLI\gh.exe'
foreach ($r in 'zg7681/myron-device','zg7681/UniXNU-myron','zg7681/NativeUfs-myron','zg7681/NativeAdreno-myron','zg7681/AdrenoMetal','zg7681/ArmCpu','UniXNU/UniXNU','UniXNU/UniXNU-sheng','oosexgang/hackios-xnu-kernel') {
  "=== $r ==="; & $gh api "repos/$r/commits?per_page=3" --jq '.[] | "\(.commit.author.date[0:16]) \(.commit.message|split("\n")[0])"'
}
```

代理没起时用直连（上面两行清空 `*_PROXY`）；`git push` 走不通时可用 GitHub contents API 发文件。
