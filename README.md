# Redmi K50 (rubens / MT6895) → Ubuntu 26.04 LTS

[![Target](https://img.shields.io/badge/target-Redmi%20K50%20(rubens)-blue)]()
[![SoC](https://img.shields.io/badge/SoC-MediaTek%20MT6895-green)]()
[![Ubuntu](https://img.shields.io/badge/Ubuntu-26.04%20LTS%20(resolute)-E95420)]()
[![Kernel](https://img.shields.io/badge/kernel-7.2.0-yellow)]()

把 Redmi K50 变成一台运行 **Ubuntu 26.04 LTS** 的完整 Linux 手机 ——
**替换 Android**，带 GNOME 桌面、硬件加速 GPU、WiFi、蓝牙、传感器。

---

## 硬件支持

| 子系统 | 状态 | 驱动 / 说明 |
|---|---|---|
| **SoC** | ✅ | MT6895 (MT6895Z/TCZA) |
| **显示** | ✅ | `mediatek-drm` (下游 `mediatek_v2`)，1440×3200 |
| **背光** | ✅ | `l11a` 面板，0–4095 可调 |
| **GPU** | ✅ | **Mali-G610 via `panthor`** — `/dev/dri/card1` + `renderD128` |
| **触摸** | ✅ | `fts` (FocalTech) |
| **按键** | ✅ | `mtk-kpd`、`mtk-spmi-keys` |
| **存储** | ✅ | UFS (`ufs-mediatek`)，223 GB 全盘 |
| **WiFi** | ✅ | MT6895 CONNAC2X2 SOC7_0，2.4G + 5G |
| **蓝牙** | ✅ | BlueZ，`hci0` |
| **传感器** | ✅ | SCP + sensor hub — ALS（自动亮度）+ 加速度计 + 5 个 IIO 设备 |
| **充电** | ✅ | `mt6375` charger + `bq28z610` 电量计 |
| **USB** | ✅ | CDC-ACM 串口控制台 / gadget |
| **Docker** | ✅ | overlay2 + nftables + cgroupv2 |
| **音频** | ⚠️ | 声卡注册成功，但 `speaker_amp` 容器文件缺失 |
| **GPS** | ⚠️ | 驱动初始化失败 |
| **AppArmor** | ⚠️ | 体积超 LK 预算，已回退（见 [PITFALLS #7](docs/PITFALLS.md#7-apparmor-撑爆-lk-体积预算)） |
| **无 USB 启动** | ⚠️ | connectivity 时序竞争，未完全解决（见 [PITFALLS #8](docs/PITFALLS.md#8-wifi-上电失败与无-usb-无法启动)） |

---

## 文档

| 文档 | 内容 |
|---|---|
| **[docs/SETUP.md](docs/SETUP.md)** | **新建仓库操作指引** —— 建库、触发构建、拿产物、刷机 |
| **[docs/BUILD.md](docs/BUILD.md)** | **完整构建教程** —— 从零到刷机，含每一步的验证命令 |
| **[docs/PITFALLS.md](docs/PITFALLS.md)** | **踩坑清单（必读）** —— 13 个坑的症状/根因/修法，含方法论复盘 |
| **[docs/SOURCES.md](docs/SOURCES.md)** | **每个文件的来源** —— 逐文件说明出处与生成过程，以及怎么重新生成 |
| [.github/workflows/build.yml](.github/workflows/build.yml) | GitHub Actions 自动构建 |

> **第一次接触这个项目请先读 `PITFALLS.md`。** 那些坑合计消耗 20+ 小时，
> 其中一半浪费在"在错误的地方找证据"。第 13 节的排查纪律能帮你避开大部分弯路。

---

## 快速开始

```bash
# 1. 环境（Ubuntu 26.04 主机，16 核推荐）
sudo apt-get install -y clang lld llvm make bc bison flex libssl-dev libelf-dev \
  device-tree-compiler cpio gzip lz4 mmdebstrap qemu-user-binfmt \
  android-sdk-libsparse-utils android-sdk-build-tools git rsync

# 2. 源码
git clone https://github.com/MT6895-Mainline/linux.git kernel
cd kernel && git checkout 80d38270aa && git checkout -b rubens-ubuntu
git am ../patches/0001-rubens-port-fixes.patch
cd ..

git clone https://github.com/MT6895-Mainline/rootfs.git rootfs-builder

# 3. 配置 + 编译（⚠️ 先 dtbs 再 Image）
#    .config 放源码树根做 in-tree 构建：产出的树就是 rootfs 构建器的缓存形状
#    （cp -a 过去即可跳过它那次编译）。用 O=out 的话必须写 out/.config。
cp configs/kernel.config kernel/.config
cd kernel
make -C . ARCH=arm64 LLVM=1 dtbs                           # 步骤 1
LOCALVERSION= make -C . ARCH=arm64 LLVM=1 -j$(nproc) Image modules   # 步骤 2
cd ..

# 4. 检查体积预算（不通过就别刷）
./scripts/verify-kernel.sh kernel
```

完整流程（含 rootfs 构建、boot.img 打包、刷机）见 **[docs/BUILD.md](docs/BUILD.md)**。

---

## 关键约束（会决定成败）

LK 是厂商 bootloader，有**硬性约束**，违反就复位循环：

| 约束 | 值 | 当前 |
|---|---|---|
| 内核 `image_size` | `< 0x3640000` (54.25 MiB) | `0x3630000` (54.188 MiB) — **余量仅 64 KiB** |
| ramdisk 大小 | `~< 4 MiB` | 819,879 字节 (20%) |
| boot 分区 | 64 MiB | boot.img 17.9 MiB |
| `os_version` | `≥ 12.0.0` (anti-rollback) | 12.0.0 |

**64 KiB 的余量意味着：任何新增的内建代码都可能把设备推入复位循环。**
新增驱动请用 `=m`（模块），不要用 `=y`。

---

## 目录结构

```
.
├── README.md
├── docs/
│   ├── SETUP.md                      新建仓库操作指引
│   ├── BUILD.md                      完整构建教程
│   ├── PITFALLS.md                   踩坑清单（必读）
│   ├── HARDWARE.md                   硬件支持矩阵与已知无害警告
│   └── SOURCES.md                    每个文件的来源与生成过程
├── configs/
│   ├── kernel.config                 完整 .config（权威、可直接用）
│   ├── rubens-ubuntu-overlay.config  相对基线的最小差分（便于理解）
│   └── mt6895-fixups.config          禁用编译不过的其他 SoC 音频
├── patches/
│   └── 0001-rubens-port-fixes.patch  移植补丁（5 个文件）
├── scripts/
│   ├── verify-kernel.sh              编译后尺寸/版本/DTB 门禁
│   ├── make-bootimg.sh               解包 ramdisk + 注入固件 + 4 个补丁 + 打包 + 校验
│   ├── flash.sh                      只打印刷机命令（刻意不自动执行）
│   ├── extract-overlay.sh            从 kernel.config 重新生成差分
│   └── ci-summary.sh                 GitHub Actions Job Summary
├── ramdisk-proven.lz4                ⚠️ 真机验证过的 ramdisk 基线，必须保留
├── firmware/                         厂商固件（本仓库存在的理由，建议 private）
└── .github/workflows/build.yml
```

---

## 验证状态

诚实标注每一项的验证程度，避免误用：

| 组件 | 状态 | 证据 |
|---|---|---|
| `configs/kernel.config` | ✅ **实机验证** | 用它编译出的内核在设备上启动，WiFi/BT/GPU/传感器全部工作 |
| `patches/0001-*.patch` | ✅ **实机验证** | 应用后的内核已刷入并运行 |
| `ramdisk-proven.lz4` | ✅ **实机验证** | 这份字节在设备上成功启动过（sha256 `b143356b…`） |
| `scripts/verify-kernel.sh` | ✅ **实测通过** | 对真实产物运行，0 项失败 |
| `scripts/make-bootimg.sh` | ⚠️ **端到端逻辑验证，未刷机** | 生成的 boot.img 与实机验证过的镜像**内核逐字节一致、文件大小一致**，`/init` 的功能点计数全部相同（差异仅为注释）。**但这一份尚未在设备上启动过** |
| `scripts/flash.sh` | ✅ **实测通过** | 只打印命令，不执行 |
| `scripts/extract-overlay.sh` | ✅ **实测通过** | 生成了 50 项差分 |
| `.github/workflows/build.yml` | ⚠️ **内核段已在 CI 实测通过；rootfs 段未跑** | **已实测通过**：克隆内核 → 应用补丁 → 清理 → 写配置 → 编 dtbs → 编内核与模块 → 门禁校验（run 7 的全部 16 步 ✅）。三个生成类 step 抽出执行后，打补丁的 `build.sh` 与本地已验证版本**逐字节相同**（md5 `669cee45…`）。内核缓存方案已离线验证：精简到 4.6 GB 后 `make modules_install` 仍能装全 1608 个模块。**未验证**：rootfs 构建（mmdebstrap 的 mount 权限、清华镜像可达性）与 boot.img 打包 |
| `docs/HARDWARE.md` 的数据 | ✅ **实机采集** | 全部来自设备上的 `dmesg` / `/sys` |

**首次使用时建议**：

1. 先跑 `scripts/verify-kernel.sh` 确认体积在预算内
2. 用 `scripts/make-bootimg.sh` 生成 boot.img 后，**先只刷 boot 分区**（不动 userdata），
   验证能启动
3. 确认无误后再刷 userdata

**已知未完成**：

- `mt6895-firstboot.service` 在镜像里**未启用**，所以每次重刷 rootfs 后都要手动
  `resize2fs`（见 [PITFALLS §9](docs/PITFALLS.md#9-mt6895-firstboot-从未运行)）
- 无 USB 启动的时序问题（见 [PITFALLS §8](docs/PITFALLS.md#8-wifi-上电失败与无-usb-无法启动)）
- 内存只识别到 7.2 GiB（硬件 12 GiB，DTB `/memory` 节点未更新）

---

## GitHub Actions

`.github/workflows/build.yml` 支持**手动触发并指定内核来源**：

| 输入 | 留空时 |
|---|---|
| 内核仓库地址 | 用默认 `MT6895-Mainline/linux` |
| 分支名 | 填了地址则**自动探测主分支**；否则用 `port/rubens-clean` |
| commit / tag | 用该分支**最新提交**（三个都留空才用已验证的 `80d38270aa`） |
| 打进 GNOME 桌面 | 否（镜像约 130 MB；勾选后约 1.5 GB） |
| 强制重编内核 | 否（默认复用 `actions/cache` 里的内核编译结果） |

**内核编译结果会跨运行缓存**（约 1 GB，键含内核 commit + 配置 + 补丁的指纹）。
实测 runner 编一次内核要 **77 分钟**，所以后半段步骤失败后重跑时，
这一次的编译会被直接跳过——只等 rootfs 的十几分钟。
详见 [docs/BUILD.md §4.1b](docs/BUILD.md)。

仓库里**只放从 GitHub 下载不到的文件**（固件、ramdisk 基线、配置、补丁），
内核源码和 rootfs 构建器都在运行时克隆。**总大小约 4.5 MB。**

**固件不走 secret** —— 直接提交在 `firmware/` 里（建议仓库设为 private）。
详见 **[docs/SETUP.md](docs/SETUP.md)**。

**不能自动化**：刷入设备（需物理连接且清空数据）、设备端交互配置。

---

## 刷机警告

> ⚠️ **刷入会清空 Android 及全部用户数据，不可逆。**
>
> ⚠️ **两个槽位（A/B）的重试次数有限**（各 6 次）。连续启动失败会把槽位标记
> `unbootable`。刷入新 boot 分区能恢复，但**不要在没把握时反复试启动**。
>
> ⚠️ **永远不要运行小米 ROM 里的 `flash_all*.sh`** —— 那会连 preloader 一起覆盖，
> 变砖风险极高。
>
> ⚠️ 刷机前务必备份原厂 boot 分区：
> ```bash
> fastboot getvar current-slot          # 确认当前槽
> adb shell su -c "dd if=/dev/block/by-name/boot_a of=/sdcard/boot_a.img"
> adb pull /sdcard/boot_a.img           # 保存好，这是回滚的唯一手段
> ```

---

## 上游项目

| 项目 | 说明 |
|---|---|
| [MT6895-Mainline/linux](https://github.com/MT6895-Mainline/linux) | 内核（`port/rubens-clean` 分支） |
| [MT6895-Mainline/rootfs](https://github.com/MT6895-Mainline/rootfs) | rootfs 构建器 |
| [MT6895-Mainline/initramfs](https://github.com/MT6895-Mainline/initramfs) | initramfs |
| [MT6895-Mainline/quirks](https://github.com/MT6895-Mainline/quirks) | 设备适配笔记 |
| B 站 BV1YZYe6TE3T | 作者视频教程 |

本项目的构建基线：内核 commit **`80d38270aa`**（2026-09-19）。

---

## 许可与免责

- 内核补丁与构建脚本：跟随上游（GPL-2.0）
- **厂商固件（`firmware/`）是专有 blob** —— 随仓库分发只是为了 CI 能构建出
  可直接刷入的镜像；公开前请自行确认合规性，建议把仓库设为 private。
  逐个文件的来源见 [docs/SOURCES.md](docs/SOURCES.md#5-firmware)
- 本教程仅用于**你自己拥有的设备**。刷机有风险，作者不承担任何责任
