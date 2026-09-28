# Redmi K50 (rubens / MT6895) 移植 Ubuntu 26.04 LTS —— 完整构建教程

从零开始，在一台 Ubuntu 主机上构建出可刷入 Redmi K50 的**内核 + 根文件系统 + 启动镜像**，
并刷入设备运行完整的 Ubuntu 26.04 桌面。

> 本文档记录的是**一台真实设备上验证成功的完整流程**，包括所有踩过的坑和它们的修法。
> 文末的 `PITFALLS.md` 是踩坑清单，**建议先通读一遍再动手** —— 那些坑会浪费你数小时。

---

## 0. 最终成果

在 Redmi K50（`22041211AC` / codename `rubens` / SoC MT6895）上运行：

| 组件 | 状态 | 说明 |
|---|---|---|
| 发行版 | ✅ Ubuntu 26.04 LTS (`resolute`) | 清华镜像源 |
| 内核 | ✅ Linux 7.2.0 | mainline 移植 |
| 桌面 | ✅ GNOME (GDM + mutter) | **有 GPU 硬件加速** |
| GPU | ✅ Mali-G610 via `panthor` | `/dev/dri/card1` + `renderD128` |
| 显示 | ✅ `mediatek-drm` 1440×3200 | 背光可控 (`l11a`) |
| 触摸 | ✅ `fts` 触摸屏 | |
| WiFi | ✅ MT6895 CONNAC2X2 SOC7_0 | 5 GHz 可用 |
| 蓝牙 | ✅ `hci0` UP RUNNING | BlueZ |
| 传感器 | ✅ SCP + sensor hub | ALS + 加速度计，5 个 IIO 设备 |
| Docker | ✅ overlay2 + nftables + cgroupv2 | 容器可用 |
| 存储 | ✅ 223 GB (userdata 全盘) | 替换 Android |
| 串口控制台 | ✅ USB CDC-ACM (`ttyGS0`) | root 登录 + 免密 sudo |

**已知限制**（不影响日常使用）：

- 无 AppArmor（内核体积超预算，见 `PITFALLS.md` §7）
- **拔掉 USB 无法启动**（WiFi/BT 内建驱动与 rootfs 挂载的时序竞争，见 `PITFALLS.md` §8）
- 无音频输出（`speaker_amp` 容器文件缺失）
- 无 GPS（驱动初始化失败）

---

## 1. 背景与架构

### 1.1 上游项目

内核来自 **[MT6895-Mainline/linux](https://github.com/MT6895-Mainline/linux)** 的
`port/rubens-clean` 分支，作者 **InvalidName**（B 站 BV1YZYe6TE3T）。

本教程构建基线：**commit `80d38270aa`**（2026-09-19）

比它更新的话，本文档的配置差异可能需要重新适配；比它旧的话会缺少 WiFi/蓝牙/传感器支持。

### 1.2 启动链路

这是理解**所有坑**的关键 —— 请务必看懂：

```
MTK Preloader
  └─ LK (Little Kernel, 厂商 bootloader)
       ├─ 读取 boot_a 分区的 boot.img
       ├─ 检查 arm64 头部 image_size 是否在预算内  ← 超过就复位循环！
       └─ 跳转到内核
            └─ Linux (内建驱动在此刻开始 probe，约 1.2~1.5 秒)
                 │  ⚠️ 此时 rootfs 还没挂载！
                 │     所有内建驱动只能用 initramfs 里的文件
                 │
                 └─ initramfs (来自 boot.img 的 ramdisk)
                      ├─ 挂载 /proc /sys /dev
                      ├─ 启动 USB 串口 shell
                      ├─ 按 GPT 分区名查找 "userdata"
                      ├─ 挂载它，检查 /sbin/init
                      ├─ 从 "nvdata" 分区提取 WiFi/BT NVRAM → rootfs
                      └─ exec switch_root → Ubuntu systemd   (约 3.3 秒)
```

**两个硬约束**（LK 强制的，无法绕过）：

| 约束 | 值 | 后果 |
|---|---|---|
| 内核 `image_size` | `< 0x3640000` (54.25 MiB) | 超过 → 复位循环 |
| ramdisk 大小 | `~< 4 MiB` | 超过 → 复位循环 |

**一个时序陷阱**（本项目的核心难点）：

内建驱动在 **1.2~1.5 秒** probe，而 rootfs 在 **3.3 秒**才挂载。
所以任何内建驱动需要的固件/配置文件，**必须在 initramfs 里**，否则
`request_firmware()` 返回 `-ENOENT` 且**大多数驱动不会重试**。

### 1.3 与 mainline 的差异

上游不是纯 mainline，而是**混合栈**：

| 子系统 | 采用 | 说明 |
|---|---|---|
| 显示 | 下游 `mediatek_v2` | mainline `mtk_drm` 不支持 MT6895 显示控制器 |
| GPU | mainline `panthor` | Mali-G610 (CSF 架构) |
| WiFi/BT | 下游 `connectivity` | CONNAC2X2 |
| SCP | 下游 `tinysys` | 传感器依赖它 |
| 存储 | mainline `ufs-mtk` | |

这解释了一个反复出现的模式：**同一功能存在"上游版"和"厂商版"两套驱动，导出同名符号，必须二选一**。

---

## 2. 环境准备

### 2.1 主机要求

本文在 **Ubuntu 26.04.1 LTS / 16 核 / 32 GB RAM** 上验证。

| 项目 | 最低 | 推荐 |
|---|---|---|
| 磁盘 | 60 GB | 120 GB（含源码树、构建产物、rootfs 镜像） |
| 内存 | 16 GB | 32 GB（`-j16` 编译峰值约 12 GB） |
| 核数 | 8 | 16（编译时间：8 核约 35 分钟，16 核约 15 分钟） |

### 2.2 安装工具链

```bash
sudo apt-get update
sudo apt-get install -y \
  clang lld llvm \
  make bc bison flex libssl-dev libelf-dev \
  device-tree-compiler \
  cpio gzip xz-utils zstd lz4 \
  python3 python3-pip \
  git rsync curl wget \
  mmdebstrap qemu-user-binfmt qemu-user-static \
  android-sdk-libsparse-utils \
  android-sdk-build-tools
```

**关键工具说明**：

| 工具 | 用途 | 注意 |
|---|---|---|
| `clang` + `lld` | 交叉编译内核（`LLVM=1`） | 需要 v20+，本文用 21.1.8 |
| `mmdebstrap` | 构建 rootfs | 需要 1.5+，本文用 1.5.7 |
| `qemu-user-binfmt` | 在 x86 主机上跑 arm64 的 chroot | **26.04 已无 `qemu-user-static` 包，用这个** |
| `simg2img` / `img2simg` | 处理 Android sparse 镜像 | 来自 `android-sdk-libsparse-utils` |
| `mkbootimg` | 打包 boot.img | 见下 |
| `lz4` | 压缩 ramdisk | **必须用 `/usr/bin/lz4`（1.10.0），不要用 conda 的 1.9.4** |

### 2.3 获取 mkbootimg

AOSP 的 `mkbootimg` 不一定在发行版仓库里。三种方式：

```bash
# 方式 1：系统包（推荐先试）
sudo apt-get install -y android-sdk-build-tools
command -v mkbootimg

# 方式 2：pip
pip install --user mkbootimg

# 方式 3：从 AOSP 源码编译
#   https://android.googlesource.com/platform/system/tools/mkbootimg/
```

验证：

```bash
mkbootimg --help 2>&1 | head -3
```

### 2.4 获取源码

```bash
WORK=$HOME/rubens-build
mkdir -p "$WORK" && cd "$WORK"

# ── 内核源码
git clone https://github.com/MT6895-Mainline/linux.git kernel
cd kernel
git checkout 80d38270aa          # 本文验证的基线
git checkout -b rubens-ubuntu
cd ..

# ── rootfs 构建器
git clone https://github.com/MT6895-Mainline/rootfs.git rootfs-builder
```

### 2.5 获取厂商固件（**必须自行提取，不能分发**）

厂商固件（WiFi 固件、NVRAM、Mali 固件）**不在仓库里**，需要你从自己的设备提取。

**方法**：从设备 root 权限下提取，或用 MTK 工具解包。

本项目用到的固件清单（放在 `firmware/`，会被 rootfs 构建脚本使用）：

```
firmware/
├── WIFI_RAM_CODE_soc7_0_1b_t_1.bin      1,203,356   WiFi 固件
├── soc7_0_ram_mcu_1b_t_1_hdr.bin          147,120
├── soc7_0_ram_bt_1b_t_1_hdr.bin           599,992
├── soc7_0_ram_wmmcu_1b_t_1_hdr.bin        479,640
├── BT_FW.cfg                                  443
├── wifi.cfg                                 1,171
├── conninfra.cfg                               17   ← 关键，见 PITFALLS §8
├── regulatory.db                              -   wireless-regdb
├── arm/mali/arch10.8/mali_csffw.bin       282,624   ← 关键，见 PITFALLS §6
├── aw8697_haptic.bin
├── aw8697_rtp_1.bin
├── tfa98xx.cnt
├── st_fts_L11a.ftb                           触摸屏
├── stm_fts_production_limits.csv
└── mali_csffw_reload.bin
```

> **WiFi NVRAM**（`WIFI`、`WIFI_CUSTOM`、`BT_Addr`）**不在这里** —— 它们在设备的
> `nvdata` 分区里，由 initramfs 在启动时自动提取。见 §5.3。

---

## 3. 构建内核

### 3.1 应用移植补丁

上游基线已经包含大部分 rubens 支持，但还需要一组本地修复：

```bash
cd "$WORK/kernel"
git am /path/to/patches/0001-rubens-port-fixes.patch
```

这个补丁包含 5 个文件：

| 文件 | 作用 |
|---|---|
| `mt6895-xiaomi-rubens.dts` | 板级设备树调整 |
| `mt6895-xiaomi-xaga.dts` | 同上（共享部分） |
| `drivers/misc/rubens-bootlog.c` | bootlog 在 initmem 释放后仍能定位分区 |
| `tools/build-rubens-bootimg.sh` | LK 安全的 boot.img 打包器 |
| `tools/build-rubens-initramfs-min.sh` | 精简 initramfs 构建器 |

**为什么必须提交而不是留作未提交改动**：`scripts/setlocalversion` 对**脏工作区**会
给内核版本追加 `+`，导致 `uname -r` 变成 `7.2.0+`，于是 `/lib/modules/7.2.0` 里的
**全部 1608 个模块都加载不了**。见 `PITFALLS.md` §4。

### 3.2 生成内核配置

**推荐做法：直接使用本文档附带的、已验证的配置**

`.config` 放在哪里**取决于你用哪条路径构建**，放错位置会直接报
`The source tree is not clean` 而中止（内核 `Makefile:709` 的守卫）：

| 构建方式 | `.config` 应该放在 | 原因 |
|---|---|---|
| 自己跑 `make -C . O=out` | `out/.config` | 源码树根**不能**有 `.config`，否则守卫触发 |
| 交给 `build.sh` 构建 | `$WORK/kernel/.config`（即 `$KBOUT`） | `$KBOUT` 是 `git archive` 出来的干净树，是它的构建根 |

**路径 A —— 自己编译（对应 §3.4）：**

```bash
mkdir -p "$WORK/kernel/out"
cp /path/to/configs/kernel.config "$WORK/kernel/out/.config"   # ← out/，不是源码树根
```

**路径 B —— 用 `rootfs/build.sh` 构建（对应 §5）：**

```bash
cp /path/to/configs/kernel.config "$WORK/kernel/.config"       # ← $KBOUT，合法
```

后者之所以合法，是因为 `build.sh` 先执行 `git archive | tar -x -C "$KBOUT"`
解出一棵**没有构建残留**的树，再在其中 in-tree 构建。源码树根的守卫只在
`O=out`（`KBUILD_OUTPUT` 已设置）时才会检查 `$(srctree)/.config`。

或者，如果你需要重新生成（例如换了上游 commit）：

```bash
cd "$WORK/kernel"

# 1) 平台默认 + 设备配置
make ARCH=arm64 LLVM=1 O=out defconfig
./scripts/kconfig/merge_config.sh -m -O out \
    arch/arm64/configs/defconfig \
    arch/arm64/configs/rubens.config

# 2) 禁用编译不过的其他 SoC 音频前端
./scripts/kconfig/merge_config.sh -m -O out out/.config \
    /path/to/configs/mt6895-fixups.config

# 3) 叠加本项目的全部覆盖
./scripts/kconfig/merge_config.sh -m -O out out/.config \
    /path/to/configs/rubens-ubuntu-overlay.config

# 4) 解析依赖（必须，否则有些项会被静默丢弃）
make ARCH=arm64 LLVM=1 O=out olddefconfig
```

### 3.3 配置项详解

本文档附带两份配置：

- **`configs/kernel.config`** —— 完整 `.config`（328 KB），**权威、可直接用**
- **`configs/rubens-ubuntu-overlay.config`** —— 相对上游基线的**最小差分**（43 项），
  便于理解每一项为什么存在

关键项分组说明：

#### A. 设备识别与存储（上游已提供，勿改）

```
CONFIG_XIAOMI_RUBENS=y              Image 内嵌 rubens DTB，setup.c 用它替换 LK 的 FDT
CONFIG_SCSI_UFS_MEDIATEK=y          UFS 存储（必须内建，否则挂不了 rootfs）
CONFIG_EXT4_FS=y                    根文件系统
CONFIG_DEVTMPFS_MOUNT=y             /dev 自动挂载
```

#### B. 调试通道（**本项目最重要的一项**）

```
CONFIG_PSTORE=y
CONFIG_PSTORE_BLK=y                 崩溃日志写入块分区（不是 RAM）
CONFIG_PSTORE_BLK_BLKDEV="/dev/sdc81"   oops 分区
CONFIG_PSTORE_BLK_KMSG_SIZE=1024
CONFIG_PSTORE_BLK_PMSG_SIZE=64
CONFIG_PSTORE_BLK_CONSOLE_SIZE=4096
CONFIG_PSTORE_BLK_MAX_REASON=2
CONFIG_MEDIATEK_WATCHDOG=y          看门狗
CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED=y
```

**没有 `PSTORE_BLK`，启动失败就只能靠猜。** 上游 `rubens.config` **没有**这一项。

#### C. 体积控制（决定能否启动）

```
# CONFIG_KALLSYMS_ALL is not set    省约 3.2 MiB！开着的唯一目的是 /proc/kallsyms 全符号
# CONFIG_LOCALVERSION_AUTO is not set  避免版本号带 + 后缀
# CONFIG_PHY_MTK_MIPI_DSI is not set  该驱动在 7.2 上编译失败（用了已删除的 clk_ops.round_rate）
# CONFIG_MTK_CMDQ is not set        与 MTK_CMDQ_MBOX_EXT 符号冲突
```

#### D. 连通性（WiFi / 蓝牙）

```
CONFIG_MTK_COMBO=y                  → 自动带上 WIFI / CHIP_CONSYS_6895（默认 y）
CONFIG_MTK_BTIF=y
CONFIG_BT=y
CONFIG_RFKILL=y
CONFIG_CFG80211=y
CONFIG_MTK_CONNSYS_DEDICATED_LOG_PATH=y
```

#### E. 传感器（SCP）

```
CONFIG_MTK_TINYSYS_SCP_SUPPORT=y    厂商 RV 版 SCP（传感器 hub 依赖它）
CONFIG_MTK_TINYSYS_SCP_LOGGER_SUPPORT=y
CONFIG_MTK_SCP=y                    这个必须被覆盖为关闭！见下
# CONFIG_MTK_SCP is not set         上游版 remoteproc，与厂商版符号冲突
# CONFIG_RPMSG_MTK_SCP is not set
CONFIG_MTK_SENSORHUB=y
CONFIG_IIO=y
```

#### F. GPU

```
CONFIG_DRM_PANTHOR=y                Mali-G610（CSF 架构）。注意：内建 → 固件必须在 initramfs
CONFIG_DRM_GPUVM=y
CONFIG_DRM_PANFROST=m               旧架构，未用但留着无害
```

#### G. Docker 支持

```
# nftables（上游只开了 xtables，Docker 的 iptables-nft 需要这个）
CONFIG_NF_TABLES=m
CONFIG_NF_TABLES_INET=y             ← 注意是 bool，写成 =m 会被静默丢弃！
CONFIG_NF_TABLES_IPV4=y
CONFIG_NF_TABLES_IPV6=y
CONFIG_NF_TABLES_NETDEV=y
CONFIG_NF_TABLES_BRIDGE=m
CONFIG_NFT_NAT=m
CONFIG_NFT_COMPAT=m
CONFIG_NETFILTER_XT_TARGET_REDIRECT=m
CONFIG_NETFILTER_XT_MATCH_STATE=m
CONFIG_VXLAN=m
```

#### H. 已回退项

```
# CONFIG_SECURITY_APPARMOR is not set   Docker 想要，但 +587 KiB 超 LK 预算。见 PITFALLS §7
# CONFIG_SECURITY_NETWORK is not set
# CONFIG_SECURITY_PATH is not set
```

### 3.4 编译

**⚠️ 必须先单独编 DTB**，否则并行构建会因 `.config not found` 失败（见 `PITFALLS.md` §3）：

```bash
cd "$WORK/kernel"

# 步骤 1：单独构建 DTB（约 1 分钟）
make -C . O=out ARCH=arm64 LLVM=1 dtbs

# 步骤 2：构建内核与模块（16 核约 15 分钟；8 核约 35 分钟）
#          LOCALVERSION= 是必须的 —— 空字符串会阻止 setlocalversion 追加 "+"
LOCALVERSION= make -C . O=out ARCH=arm64 LLVM=1 -j"$(nproc)" Image modules
```

**为什么用 `-C . O=out`**：源码树保持干净（避免 `setlocalversion` 误判），产物隔离在 `out/`。

### 3.5 编译后验证（**这一步不能跳过**）

```bash
cd "$WORK/kernel"

# ① 检查 image_size —— 决定能否启动
python3 - <<'PY'
import struct
d = open('out/arch/arm64/boot/Image','rb').read(64)
assert d[56:60] == b'ARM\x64', "不是 arm64 Image"
size = struct.unpack_from('<Q', d, 16)[0]
budget, over = 0x3640000, 0x3820000
print(f"image_size = 0x{size:x}  ({size/1048576:.3f} MiB)")
print(f"预算       = 0x{budget:x}  ({budget/1048576:.3f} MiB)")
print(f"余量       = {budget-size} 字节 ({(budget-size)/1024:.1f} KiB)")
if size < budget:
    print("✅ 在预算内")
elif size < over:
    print("⚠️ 超过已验证上限，但低于失效点 —— 有风险")
else:
    raise SystemExit("❌ 达到失效点，必定复位循环")
PY

# ② 检查内核版本字符串（必须无 + 后缀）
cat out/include/config/kernel.release
#   期望输出: 7.2.0

# ③ 检查 DTB 是否内嵌进 Image（setup.c 依赖它）
python3 - <<'PY'
import hashlib, struct
img = open('out/arch/arm64/boot/Image','rb').read()
dtb = open('out/arch/arm64/boot/dts/mediatek/mt6895-xiaomi-rubens.dtb','rb').read()
i = img.find(b'\xd0\x0d\xfe\xed')
assert i >= 0, "Image 里找不到内嵌 DTB！setup.c 会解引用不存在的符号区"
total, = struct.unpack_from('>I', img, i+4)
emb = img[i:i+total]
print(f"内嵌 DTB: {total} 字节 @ 0x{i:x}")
print(f"源码 DTB: {len(dtb)} 字节")
print("✅ 一致" if emb == dtb else "❌ 不一致 —— 内核会用错误的设备树启动")
PY

# ④ 检查关键配置真的生效了
for s in CONFIG_MTK_COMBO CONFIG_MTK_BTIF CONFIG_MTK_TINYSYS_SCP_SUPPORT \
         CONFIG_PSTORE_BLK CONFIG_DRM_PANTHOR CONFIG_NF_TABLES; do
  printf "%-42s " "$s"; grep -E "^$s=" out/.config || echo "(缺失!)"
done
```

**本文验证通过的值**：

```
image_size = 0x3630000  (54.188 MiB)   余量 64 KiB
DTB        = 83,168 字节
release    = 7.2.0
.ko        = 1608 个
Image      = 53,131,776 字节
```

### 3.6 用 Docker 的检查器交叉验证

```bash
curl -sSL -o check-config.sh \
  https://github.com/moby/moby/raw/master/contrib/check-config.sh
chmod +x check-config.sh
./check-config.sh "$WORK/kernel/out/.config"
```

`Generally Necessary` 一节应全部 `enabled`。缺 AppArmor 是**预期**的（见 `PITFALLS.md` §7），
缺 `NFT_MASQ`/`NFT_FIB`/`IPVLAN`/`IP_SCTP` 等**可选**项不影响容器运行。

---

## 4. 构建根文件系统

### 4.1 内核：先构建一次，之后自动复用

`rootfs/build.sh` **自己会编内核**（in-tree，在 `$KBOUT` 里），并且带一个内核缓存
快速路径：

```
KERNEL_CACHE="${KERNEL_CACHE:-$OUT/kernel-cache}"
命中条件：$KERNEL_CACHE/{arch/arm64/boot/Image, .config, Module.symvers} 三个都存在
```

所以最省事的做法就是**第一次直接跑 `build.sh`**（见 §4.3），它编完内核后，
后续运行会打印 `reusing the cached kernel build` 并跳过内核编译。

> ### ⚠️ 不要把 `kernel/out` 复制成缓存
>
> 一个很自然的错误做法是 `cp -a "$WORK/kernel/out" out/kernel-cache`。
> **这会失败或错得很难察觉。** 原因是 `O=out` 构建会在输出目录顶层生成一层
> 写死绝对路径的 `Makefile` 包装器：
>
> ```
> # Automatically generated by <srctree>/Makefile: don't edit
> export KBUILD_OUTPUT = <srctree>/out
> include <srctree>/Makefile
> ```
>
> 而 `build.sh` 把缓存 overlay 到 `$KBOUT` 之后，是在 `$KBOUT` 里跑
> `make modules_install`。`make` 一读到这层包装器就会**跳回它写死的那个
> `<srctree>/out`**，于是：
>
> 1. `$KBOUT` 里准备好的东西完全没被用上；
> 2. `<srctree>/.config` 存在，内核 `Makefile:709` 的守卫直接报
>    `*** The source tree is not clean`；
> 3. 模块可能装进一个**另一个**构建的 `modules.order` 所描述的路径。
>
> 本地那次"缓存命中"之所以能工作，只是因为缓存里的绝对路径恰好还指向
> 本机的 `kport/out`——**换一台机器（比如 CI runner）立刻失效**。
>
> 正确做法：让 `build.sh` 自己建一次缓存，或从 `$OUT/.work-*/kernel`
> （那是它的真实工作树，`Makefile` 是完整内核 Makefile）里取。

### 4.2 设备 profile 与发行版后端（**这两个文件上游没有**）

上游 `MT6895-Mainline/rootfs` 里：

- `devices/` 只有 `pearl.conf`、`qqcandy.conf`、`rubens.conf`、`xaga.conf`
- `distros/` 只有 `debian.sh`

也就是说 **`devices/rubens-ubuntu.conf` 和 `distros/ubuntu.sh` 都不存在**，
必须自己创建（`rubens.conf` 是给 Debian 用的，不能直接用）。

`.github/workflows/build.yml` 是在 CI 里**现场生成这两个文件**的
（见「写入设备 profile」和「写入 Ubuntu 发行版后端」两个 step），
所以本地复现时也要自己写。

`devices/rubens-ubuntu.conf` 的完整内容：

```bash
DISTRO="ubuntu"
SUITE="resolute"                          # Ubuntu 26.04 的 codename
PLATFORM_NAME="Xiaomi Redmi K50 (rubens)"
SOC="mt6895"

KERNEL_BRANCH="HEAD"
KERNEL_CONFIGS="rubens.config"
DTS="mt6895-xiaomi-rubens.dts"
KERNEL_MAKE_ARGS="LLVM=1"
KERNEL_LOCALVERSION=""                    # 空 = 7.2.0，不带 "+"

ROOTFS_LABEL="mt6895rubens"
DEFAULT_USER="ubuntu"
USERDATA_PART="/dev/sdc86"                # 内核设备节点，不是 fastboot 名
NVDATA_PART="/dev/sdc13"

PACKAGES_CORE="systemd systemd-sysv systemd-resolved openssh-server sudo kmod"

PACKAGES_EXTRA="network-manager bluez modemmanager iio-sensor-proxy \
                alsa-ucm-conf alsa-utils usbutils pciutils iproute2 \
                ethtool iw rfkill wireless-regdb wpasupplicant \
                less nano zstd e2fsprogs dosfstools \
                curl wget htop tmux ca-certificates apt-utils"
```

`distros/ubuntu.sh` 的关键点（必须自己写的原因）：**arm64 不是 Ubuntu 的主架构**，
归档在 `ports.ubuntu.com/ubuntu-ports` 而不是 `archive.ubuntu.com/ubuntu`，
而且 `mmdebstrap` 把镜像当**位置参数**（`--mirror=$url` 会以
`Unknown option: mirror` 中止）。backend 要提供 `distro_bootstrap` 和
`distro_configure` 两个函数，镜像默认用清华：

```
https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports
```

**两个容易漏掉的包**：

| 包 | 漏掉的后果 |
|---|---|
| **`wpasupplicant`** | NetworkManager **完全没有无线能力**，`wlan0` 永远 `unavailable`。见 `PITFALLS.md` §5 |
| `wireless-regdb` | 无监管域数据库，5 GHz 受限 |

**如果要桌面**，把 `ubuntu-desktop-minimal` 也加进 `PACKAGES_EXTRA`：

```
PACKAGES_EXTRA="... ubuntu-desktop-minimal ..."
```

> 代价：镜像从 132 MB 涨到约 1.5 GB，构建时间变长。
> 如果不加，也可以装完系统后在设备上 `apt install`（本文验证过，但**重刷 rootfs 会丢失**）。

### 4.3 运行构建

```bash
cd "$WORK/rootfs-builder"
sudo ./build.sh \
  --device        rubens-ubuntu \
  --distro        ubuntu \
  --suite         resolute \
  --kernel-repo   "$WORK/kernel" \
  --kernel-config "$WORK/kernel/out/.config" \
  --firmware      "$WORK/firmware" \
  --jobs          "$(nproc)" \
  --hostname      rubens \
  --root-password root
```

**耗时**：16 核约 8 分钟（mmdebstrap 约 350 秒 + 打包）。

**必须用 `sudo`**：mmdebstrap 需要 root 做 chroot、mknod、chown。

**产物**：

```
out/rootfs-rubens-ubuntu-<timestamp>.img          完整 ext4（1 GiB）
out/rootfs-rubens-ubuntu-<timestamp>-sparse.img   Android sparse（用于 fastboot）
out/rootfs-rubens-ubuntu-<timestamp>-sparse.img.gz
out/Image-rubens-ubuntu
out/dtb-rubens-ubuntu.dtb
out/KERNEL-INFO-rubens-ubuntu.txt
out/SHA256SUMS
```

### 4.4 验证 rootfs

```bash
cd "$WORK/rootfs-builder"
IMG=$(ls -t out/rootfs-rubens-ubuntu-*-sparse.img | head -1)

# 展开成 raw 便于检查
simg2img "$IMG" /tmp/rootfs.raw

# 卷标必须匹配 initramfs 的查找逻辑
dd if=/tmp/rootfs.raw bs=1 skip=$((1024+120)) count=16 2>/dev/null | tr -d '\0'
#   期望: mt6895rubens

# 模块数量
rm -rf /tmp/mods && mkdir -p /tmp/mods
debugfs -R "rdump /lib/modules/7.2.0/kernel /tmp/mods" /tmp/rootfs.raw >/dev/null 2>&1
find /tmp/mods -name '*.ko' | wc -l
#   期望: 1608

# 关键文件
for p in /sbin/init /lib/systemd/systemd /usr/bin/apt /usr/bin/nmcli \
         /usr/sbin/wpa_supplicant /lib/firmware/arm/mali/arch10.8/mali_csffw.bin \
         /lib/firmware/conninfra.cfg; do
  printf "%-56s " "$p"
  debugfs -R "stat $p" /tmp/rootfs.raw 2>/dev/null | grep -q '^ *Inode:' && echo "✅" || echo "❌"
done
```

---

## 5. 构建启动镜像（boot.img）

这一步把 **内核 + initramfs** 打包成 LK 能识别的格式，是整个流程中最需要精确的部分。

### 5.1 initramfs 需要做的三件事

我们的 ramdisk 里的 `/init` 必须完成：

1. **挂载伪文件系统**（`/proc` `/sys` `/dev` `/run` `/tmp`）
2. **启动 USB 串口 shell**（`/dev/ttyGS0`）—— 否则启动过程完全不可观测
3. **查找并切换根**：
   - 按 **GPT 分区名**（不是设备节点名！）查找 `userdata`
   - 挂载 ext4，检查 `/sbin/init`
   - 从 `nvdata` 提取 WiFi/BT NVRAM 到 rootfs
   - `exec switch_root`

**两个 initramfs 特有的陷阱**（都踩过）：

#### 陷阱 1：busybox 没有 `basename`

```sh
# ❌ 错误实现（原版 fork 的写法）
find_part_by_name() {
    for b in /sys/class/block/*; do
        [ -f "$b/partition" ] || continue
        case "$(cat $b/uevent)" in
        *PARTNAME=$1*) echo "/dev/$(basename "$b")" ;;   # ← basename 不存在！
        esac
    done
}
```

`basename` 不是 busybox 内建 applet，命令替换返回空 → 函数返回 `/dev/` →
`mount -t ext4 /dev/ /mnt/root` 必然失败 → **判定"无可用 rootfs"，无法启动**。

```sh
# ✅ 正确：纯 shell 参数展开，不依赖任何 applet
echo "/dev/${b##*/}"
```

#### 陷阱 2：`switch_root` 前必须杀掉 initramfs 的后台进程

`exec switch_root` **只替换 PID 1**，不清理 PID 1 启动的其他进程。
initramfs 里用 `&` 起的 shell 循环会存活下来，文件描述符仍指向**旧根的** `/dev/tty1`，
于是**永久向屏幕刷屏**（`/init: line :sleep: not found`）：

```sh
# ✅ 在 exec switch_root 之前
kill_old_shells() {
    self=$$
    for p in $SPAWNED_PIDS; do
        [ "$p" = "$self" ] && continue
        kill -9 "$p" 2>/dev/null || true
    done
    for d in /proc/[0-9]*; do
        pid=${d##*/}
        [ "$pid" = "1" ] && continue
        [ "$pid" = "$self" ] && continue          # 避免自杀
        case "$(cat $d/cmdline 2>/dev/null | tr '\0' ' ')" in
        *"/bin/sh /init"*) kill -9 "$pid" 2>/dev/null || true ;;
        esac
    done
    sleep 1
    return 0
}
```

### 5.2 initramfs 必须包含的固件

**这是本项目最关键的发现。** 内建驱动在 rootfs 挂载前 probe，
所以它要的固件必须在 initramfs 里：

```bash
mkdir -p ramdisk/lib/firmware/arm/mali/arch10.8
install -m 0644 firmware/arm/mali/arch10.8/mali_csffw.bin \
        ramdisk/lib/firmware/arm/mali/arch10.8/mali_csffw.bin
install -m 0644 firmware/conninfra.cfg \
        ramdisk/lib/firmware/conninfra.cfg
```

| 固件 | 大小 | 缺少的后果 |
|---|---|---|
| `arm/mali/arch10.8/mali_csffw.bin` | 282,624 | GPU `probe failed`，**无硬件加速**（GNOME 卡顿） |
| `conninfra.cfg` | 17 | WiFi 首次上电失败，`Get conf fail` 刷屏 |

**注意 `conninfra.cfg` 只需 17 字节**（内容是 `co_clock_flag=1`），但缺失会导致
整个 WiFi 栈上电失败 —— 详见 `PITFALLS.md` §8。

### 5.3 NVRAM 由 initramfs 从 nvdata 提取

WiFi 的 MAC 地址/校准数据、蓝牙地址**不在固件包里**，在设备的 `nvdata` 分区：

```sh
# initramfs /init 中的 provisioning 逻辑
part=$(find_part_by_name nvdata) || { msg "no nvdata partition"; return 0; }
mkdir -p /mnt/nvdata
mount -t ext4 -o ro "$part" /mnt/nvdata
src=/mnt/nvdata/APCFG/APRDEB
dst=/mnt/root/lib/firmware/mediatek/mt6895
mkdir -p "$dst"

[ -f "$src/WIFI" ]        && cp "$src/WIFI"        "$dst/WIFI"
[ -f "$src/WIFI_CUSTOM" ] && cp "$src/WIFI_CUSTOM" "$dst/WIFI_CUSTOM"
[ -f "$src/BT_Addr" ]     && cp "$src/BT_Addr"     "$dst/BT_Addr"

umount /mnt/nvdata
```

因为这部分在 `switch_root`（约 3.3 秒）**之前**完成，
WiFi 驱动的延迟重试（每 250 ms 一次，最多 120 秒）能在 19 秒左右找到它。

### 5.4 打包 boot.img

```bash
#!/bin/bash
set -eu

KERNEL_IMAGE=out/arch/arm64/boot/Image
RAMDISK_DIR=ramdisk                 # 已解包的 initramfs 目录
OUT=boot-ubuntu.img

# ── 1. 压缩内核（必须 gzip -n：不加时间戳/文件名，保证可复现）
gzip -n -9 -c "$KERNEL_IMAGE" > /tmp/kernel.gz

# ── 2. 打包 initramfs
#     cpio newc 格式，owner 归零
(cd "$RAMDISK_DIR" && find . -print0 | \
    LC_ALL=C cpio --null -o -H newc --owner=0:0 --quiet > /tmp/ramdisk.cpio)

#     ⚠️ 必须用 LZ4 legacy 格式 —— 内核的 initramfs 解压器只认这个
#        魔数必须是 02 21 4c 18
/usr/bin/lz4 -l -9 -f /tmp/ramdisk.cpio /tmp/ramdisk.lz4

# ── 3. 检查 ramdisk 预算
RD=$(stat -c %s /tmp/ramdisk.lz4)
[ "$RD" -lt 4194304 ] || { echo "FAIL: ramdisk $RD 超过 4 MiB 预算"; exit 1; }

# ── 4. 打包
mkbootimg \
    --header_version 4 \
    --os_version    12.0.0 \
    --os_patch_level 2024-09 \
    --kernel  /tmp/kernel.gz \
    --ramdisk /tmp/ramdisk.lz4 \
    --output  "$OUT"

# ── 5. 修正 boot_signature_size（LK 会读这个字段，必须为 0x1000）
python3 - "$OUT" <<'PY'
import struct, sys
p = sys.argv[1]
d = bytearray(open(p, 'rb').read())
struct.pack_into('<I', d, 1580, 0x1000)
open(p, 'wb').write(d)
print("boot_signature_size -> 0x1000")
PY
```

**为什么 `os_version`/`os_patch_level` 用 `12.0.0`/`2024-09`**：

LK 有 anti-rollback 检查（`anti_version=1`）。这两个字段不能低于设备当前值。
`12.0.0` + `2024-09` 与设备原厂 boot.img 持平，所以安全。
**如果你换用更新的值也行，但绝不能更低。**

### 5.5 验证 boot.img

```bash
# 结构验证
unpack_bootimg --boot_img boot-ubuntu.img --out /tmp/verify

# 内核字节一致
gzip -dc /tmp/verify/kernel | cmp - "$KERNEL_IMAGE" && echo "✅ 内核一致"

# ramdisk 格式（必须是 LZ4 legacy）
xxd -p -l4 /tmp/verify/ramdisk
#   期望: 02214c18

# ramdisk 里的固件
/usr/bin/lz4 -l -d -f /tmp/verify/ramdisk /tmp/rd.cpio
cpio -it < /tmp/rd.cpio | grep -E 'firmware|init'
#   期望看到: ./lib/firmware/arm/mali/arch10.8/mali_csffw.bin
#            ./lib/firmware/conninfra.cfg
#            ./init

# 头部字段
python3 - <<'PY'
import struct, os
d = open('boot-ubuntu.img','rb').read(4096)
ks, rs = struct.unpack_from('<II', d, 8)
hv, hs = struct.unpack_from('<II', d, 36) [0], struct.unpack_from('<I', d, 20)[0]
print(f"header_version={hv}  header_size={hs}")
print(f"kernel_size={ks}  ramdisk_size={rs}")
print(f"signature_size@1580=0x{struct.unpack_from('<I',d,1580)[0]:x}")
# 文件总长 = page + align(kernel) + align(ramdisk)，page 固定 4096
expected = 4096 + ((ks+4095)//4096)*4096 + ((rs+4095)//4096)*4096
print(f"期望大小={expected}  实际={os.path.getsize('boot-ubuntu.img')}")
PY
```

---

## 6. 刷入设备

> ⚠️ **以下操作会清空 Android 及全部用户数据。开始前请确认已备份。**

### 6.1 前置检查

```bash
# 设备进 fastboot
adb reboot bootloader        # 或手动：长按电源 10 秒 → 音量下 + 电源
fastboot devices             # 应输出序列号

# 关键：查看槽位状态
for v in current-slot slot-retry-count:a slot-unbootable:a \
         slot-retry-count:b slot-unbootable:b; do
  printf "%-24s " "$v"; fastboot getvar $v 2>&1 | head -1
done
```

**MTK LK 的槽位行为**（很重要）：

- 每个槽有 6 次启动重试；连续失败会递减，归零后标记 `unbootable`
- **`fastboot --set-active=X` 必须跟一次 `fastboot reboot-bootloader` 才生效**
- 即使 `unbootable=yes`，**刷入该槽的 boot 分区后 LK 仍会尝试启动**（实测）
- **不要用 `fastboot boot`** —— MTK LK 不支持（报 `unknown command`）

### 6.2 刷入

```bash
# ① 刷内核
fastboot flash boot_a boot-ubuntu.img

# ② 刷根文件系统（大文件，约 13 秒）
fastboot flash userdata rootfs-rubens-ubuntu-<timestamp>-sparse.img

# ③ 重启
fastboot reboot
```

**如果需要切换到 B 槽**：

```bash
fastboot flash boot_b boot-ubuntu.img
fastboot --set-active=b
fastboot reboot-bootloader      # set_active 需要这一步才生效
fastboot reboot
```

### 6.3 观察启动

**方式 A：USB 串口**（推荐）

```bash
# 设备启动后会出现 /dev/ttyACM0
sudo picocom -b 115200 /dev/ttyACM0
#   或
sudo tio /dev/ttyACM0
```

initramfs 的日志**双写 `/dev/kmsg` 和 `/dev/ttyGS0`**，所以串口能看到完整启动过程。

**方式 B：pstore（启动失败时唯一手段）**

如果启动失败，内核 panic 前的日志会由 `pstore/blk` 写入 `oops` 分区。
需要让设备能启动到某个系统（或 Android）才能读出来。

**串口无输出时的排查顺序**：

1. `lsusb` 看设备是否枚举（`0525:a4a7` = Linux gadget，`18d1:d00d` = fastboot）
2. 检查是否有别的程序占用串口：`sudo fuser -v /dev/ttyACM0`
3. 停用 ModemManager（它会抢 `ttyACM*`）：`sudo systemctl stop ModemManager`
4. 检查 `/dev/ttyACM0` 的属组（通常是 `dialout`），确认当前用户在组里

---

## 7. 首次启动后的设备配置

### 7.1 扩容根文件系统

**镜像故意只有 1 GiB**（这样构建快、传输小），而 `userdata` 分区是 226 GiB。
需要在设备上扩容：

```bash
# ext4 支持在线扩容，挂载状态下也能做
sudo resize2fs $(findmnt -no SOURCE /)
df -h /
#   期望: 223G
```

> **为什么必须手动做**：`mt6895-firstboot.service`（本来是干这个的）**没有被启用** ——
> 它缺少 `sysinit.target.wants/` 下的符号链接。见 `PITFALLS.md` §9。

### 7.2 连接 WiFi

**关键：必须显式指定 `ifname wlan0`**，否则 NetworkManager 会把连接建到 `ap0`
（AP 模式的虚拟接口）上，然后报 `The Wi-Fi network could not be found`：

```bash
# 扫描
nmcli device wifi list

# 连接（注意 ifname）
nmcli device wifi connect "你的SSID" password "你的密码" ifname wlan0

# 验证
nmcli -t -f DEVICE,STATE,CONNECTION device status
ip -br addr show wlan0
ping -c 3 223.5.5.5
```

**如果 `wlan0` 显示 `unavailable`** —— 说明缺 `wpasupplicant`，见 `PITFALLS.md` §5。

### 7.3 IP 转发（Docker 需要）

```bash
sudo sysctl -w net.ipv4.ip_forward=1
sudo tee /etc/sysctl.d/99-docker.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
```

### 7.4 串口 getty（可选但强烈推荐）

默认只有屏幕上的 `getty@tty1`。启用串口登录：

```bash
sudo systemctl enable --now serial-getty@ttyGS0.service
#   之后 /dev/ttyACM0 就有 login 提示符
```

**登录凭据**：`root` / `root`，或 `ubuntu`（**空密码**，在 `sudo` 组且有免密 sudo）。

> GDM **默认拒绝 root 图形登录**，所以桌面用 `ubuntu` 账户。

### 7.5 GNOME 桌面

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends ubuntu-desktop-minimal

sudo systemctl set-default graphical.target
sudo reboot
```

**装完立刻做的两件事**：

```bash
# ① K50 是 1440×3200，DPI 极高，默认字会小到看不清
gsettings set org.gnome.desktop.interface text-scaling-factor 2.0

# ② 改掉默认 root 密码（设备已联网）
sudo passwd root
```

**验证 GPU 加速**（GNOME 流畅的前提）：

```bash
dmesg | grep -i panthor | head
#   期望看到: Firmware git sha: 95a25d71...
#            [drm] Initialized panthor 1.8.0 for 13000000.gpu on minor 1
ls -l /dev/dri/
#   期望: card0 (显示)  card1 (GPU)  renderD128
```

### 7.6 Docker（可选）

```bash
sudo apt-get install -y docker-ce docker-ce-cli containerd.io
sudo systemctl enable --now containerd docker

# 验证 nftables 后端（这是之前失败的那条命令）
sudo iptables-nft --wait -t nat -N DOCKER_TEST && echo "NAT OK"
sudo iptables-nft --wait -t nat -X DOCKER_TEST

sudo docker info | grep -iE 'Storage Driver|Cgroup'
#   期望: Storage Driver: overlay2   Cgroup Version: 2
sudo docker run --rm hello-world
```

---

## 8. 自动化构建（GitHub Actions）

> **本节只是原理示意。** 真正的、可直接用的 workflow 是仓库里的
> [`.github/workflows/build.yml`](../.github/workflows/build.yml)——它有 23 个 step，
> 包含手动触发输入、设备 profile 与 Ubuntu 后端的现场生成、`build.sh` 补丁等。
> 下面的片段为了讲清原理做了删减，**不要直接复制去用**。
>
> 另外：它**不使用任何 secret**。厂商固件直接提交在 `firmware/` 里
> （见 [`SOURCES.md`](SOURCES.md#5-firmware)），仓库因此建议设为 private。

**能自动化**：内核编译、配置生成、rootfs 构建、boot.img 打包、产物校验。

**不能自动化**：

| 项 | 原因 |
|---|---|
| **刷入设备** | 需要物理连接，且会清空数据 |
| **设备端配置** | 需要交互（WiFi 密码等） |

### 8.1 固件怎么进镜像

两种做法，本仓库用第一种：

| 做法 | 说明 |
|---|---|
| **直接提交 `firmware/`**（本仓库采用） | 仓库只放 GitHub 下载不到的文件 + `build.yml`；简单，但仓库必须是 private |
| base64 Secret | 适合必须公开的仓库；workflow 里用 `secrets.X \| base64 -d` 还原，代价是每次改固件都要更新 secret |

### 8.2 workflow 骨架（示意）

```yaml
# 简化示意，完整版见 .github/workflows/build.yml
name: Build rubens Ubuntu 26.04

on:
  workflow_dispatch:

jobs:
  build:
    # 宿主标签与构建容器都必须是 26.04：GitHub 的 ubuntu-24.04 自带
    # clang 18.1.3 / lz4 1.9.4，两样都会让本移植失败（见 PITFALLS.md）
    runs-on: ubuntu-26.04
    container:
      image: ubuntu:26.04          # 与本地验证环境一致的工具链
      options: --user root
    timeout-minutes: 180

    steps:
      - uses: actions/checkout@v4

      # ─────────────────────────────── 1. 工具链
      - name: Install toolchain
        run: |
          sudo apt-get update
          sudo apt-get install -y \
            clang lld llvm make bc bison flex libssl-dev libelf-dev \
            device-tree-compiler cpio gzip xz-utils zstd lz4 \
            mmdebstrap qemu-user-binfmt qemu-user-static \
            android-sdk-libsparse-utils android-sdk-build-tools \
            git rsync python3
          clang --version | head -1

      # ─────────────────────────────── 2. 获取源码
      - name: Clone kernel and rootfs builder
        run: |
          git clone --depth 1 -b port/rubens-clean \
            https://github.com/MT6895-Mainline/linux.git kernel
          cd kernel
          # 固定到验证过的 commit（--depth 1 只拿分支头，需要显式取）
          git fetch --depth 1 origin 80d38270aa
          git checkout 80d38270aa
          git checkout -b rubens-ubuntu
          cd ..
          git clone --depth 1 \
            https://github.com/MT6895-Mainline/rootfs.git rootfs-builder

      # ─────────────────────────────── 3. 应用移植补丁
      - name: Apply port patches
        run: |
          cd kernel
          git am ../patches/0001-rubens-port-fixes.patch

      # ─────────────────────────────── 4. 内核配置
      - name: Configure kernel
        run: |
          cd kernel
          cp ../configs/kernel.config .config
          make ARCH=arm64 LLVM=1 O=out olddefconfig

      # ─────────────────────────────── 5. 编译（先 dtbs！）
      - name: Build DTB
        run: cd kernel && make -C . O=out ARCH=arm64 LLVM=1 dtbs

      - name: Build kernel and modules
        run: |
          cd kernel
          LOCALVERSION= make -C . O=out ARCH=arm64 LLVM=1 \
            -j"$(nproc)" Image modules

      # ─────────────────────────────── 6. 尺寸门禁
      - name: Verify image_size budget
        run: |
          cd kernel
          python3 - <<'PY'
          import struct, sys
          d = open('out/arch/arm64/boot/Image','rb').read(64)
          assert d[56:60] == b'ARM\x64'
          size = struct.unpack_from('<Q', d, 16)[0]
          budget = 0x3640000
          print(f"image_size = 0x{size:x} ({size/1048576:.3f} MiB), budget 0x{budget:x}")
          if size >= budget:
              sys.exit(f"FAIL: 超出 LK 预算 {size-budget} 字节 —— 会复位循环")
          print(f"OK: 余量 {budget-size} 字节")
          PY
          test "$(cat out/include/config/kernel.release)" = "7.2.0"

      # ─────────────────────────────── 7. 厂商固件（从 Secret 还原）
      - name: Restore vendor firmware
        run: |
          mkdir -p firmware
          echo "${{ secrets.RUBENS_FIRMWARE_B64 }}" | base64 -d > /tmp/fw.tar.zst
          tar --zstd -xf /tmp/fw.tar.zst -C firmware
          ls -la firmware/ | head
          # 关键文件必须存在
          test -f firmware/arm/mali/arch10.8/mali_csffw.bin
          test -f firmware/conninfra.cfg
          test -f firmware/WIFI_RAM_CODE_soc7_0_1b_t_1.bin

      # ─────────────────────────────── 8. rootfs
      - name: Verify kernel artifacts
        run: |
          # 注意：不要把 kernel/out 当 build.sh 的缓存传进去，原因见本文 §4.1
          test -f kernel/out/arch/arm64/boot/Image
          test -f kernel/out/Module.symvers
          test "$(cat kernel/out/include/config/kernel.release)" = "7.2.0"

      - name: Write device profile and distro backend
        run: |
          # 上游 rootfs 仓库没有这两个文件，必须现场生成（见本文 §4.2）
          cd rootfs-builder
          mkdir -p devices distros
          cat > devices/rubens-ubuntu.conf <<'CONF'
          ... 内容见本文 §4.2 ...
          CONF
          sed -i 's/^          //' devices/rubens-ubuntu.conf
          cat > distros/ubuntu.sh <<'BACKEND'
          ... distro_bootstrap / distro_configure，见本文 §4.2 ...
          BACKEND
          sed -i 's/^          //' distros/ubuntu.sh
          chmod 0755 distros/ubuntu.sh

      - name: Build rootfs
        run: |
          cd rootfs-builder
          sudo ./build.sh \
            --device        rubens-ubuntu \
            --distro        ubuntu \
            --suite         resolute \
            --kernel-repo   "$PWD/../kernel" \
            --kernel-config "$PWD/../kernel/out/.config" \
            --firmware      "$PWD/../firmware" \
            --jobs          "$(nproc)" \
            --hostname      rubens \
            --root-password root

      # ─────────────────────────────── 9. boot.img
      - name: Build boot.img
        run: ./scripts/make-bootimg.sh

      # ─────────────────────────────── 10. 校验与上传
      - name: Verify artifacts
        run: ./scripts/verify-all.sh

      - name: Upload artifacts
        uses: actions/upload-artifact@v4
        with:
          name: rubens-ubuntu-2604-${{ github.sha }}
          path: |
            kernel/out/arch/arm64/boot/Image
            kernel/out/arch/arm64/boot/dts/mediatek/mt6895-xiaomi-rubens.dtb
            boot-ubuntu.img
            rootfs-builder/out/rootfs-rubens-ubuntu-*-sparse.img
            rootfs-builder/out/SHA256SUMS
            rootfs-builder/out/KERNEL-INFO-rubens-ubuntu.txt
          retention-days: 30
```

### 8.2 方案 B：自建 runner（推荐用于私有仓库）

固件体积约 3 MB，base64 后会膨胀到 4 MB，
**GitHub Secrets 单值上限 48 KB** —— 所以方案 A 需要把固件切成多块，很啰嗦。

**更实际的做法**：在你有权限的机器上跑 self-hosted runner，固件直接放在本地：

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux, x64]
    steps:
      - uses: actions/checkout@v4
      - name: Build
        run: |
          # firmware/ 已在 runner 上，直接引用
          sudo ./scripts/build-all.sh
```

### 8.3 完整脚本化（供 CI 调用）

建议把流程固化成三个脚本，CI 只负责编排：

| 脚本 | 职责 |
|---|---|
| `scripts/build-kernel.sh` | 配置 + 编 DTB + 编 Image/modules + 尺寸门禁 |
| `scripts/build-rootfs.sh` | 灌缓存 + mmdebstrap + 校验 |
| `scripts/make-bootimg.sh` | 解包 ramdisk + 注入固件 + 打补丁 + 打包 + 校验 |

`make-bootimg.sh` 的核心逻辑见 §5.4，加上固件注入（§5.2）和 initramfs 补丁（§5.1）。

---

## 9. 目录结构建议

放在你的仓库里：

```
.
├── README.md
├── docs/
│   ├── BUILD.md                    ← 本文档
│   ├── PITFALLS.md                 ← 踩坑清单（必读）
│   └── HARDWARE.md                 ← 硬件支持矩阵
├── configs/
│   ├── kernel.config               ← 完整 .config（权威、可直接用）
│   ├── rubens-ubuntu-overlay.config ← 相对基线的最小差分（便于理解）
│   └── mt6895-fixups.config        ← 禁用编译不过的其他 SoC 音频
├── patches/
│   └── 0001-rubens-port-fixes.patch
├── scripts/
│   ├── build-kernel.sh
│   ├── build-rootfs.sh
│   ├── make-bootimg.sh
│   ├── verify-all.sh
│   └── flash.sh                    ← 只打印命令，不自动刷
├── firmware/                       ← .gitignore！厂商固件不能提交
│   └── .gitkeep
├── .github/workflows/build.yml
└── .gitignore
```

`.gitignore`：

```gitignore
firmware/*
!firmware/.gitkeep
out/
kernel/
rootfs-builder/
*.img
*.img.gz
*.cpio
*.lz4
```

---

## 10. 快速检查清单

构建前：

- [ ] 主机 Ubuntu 26.04，clang 20+，mmdebstrap 1.5+
- [ ] `/usr/bin/lz4` 是 1.10.0（**不是 conda 的 1.9.4**）
- [ ] `mkbootimg` 可用
- [ ] 厂商固件齐备（特别是 `mali_csffw.bin` 和 `conninfra.cfg`）
- [ ] 磁盘 ≥ 60 GB 可用

内核：

- [ ] 补丁已 `git am`（工作区**干净**，否则版本号带 `+`）
- [ ] 配置用 `configs/kernel.config`
- [ ] **先 `make dtbs`，再 `make Image modules`**
- [ ] 编译时带 `LOCALVERSION=`
- [ ] `image_size < 0x3640000`
- [ ] `kernel.release == 7.2.0`
- [ ] Image 内嵌 DTB 与源码 DTB 字节一致

rootfs：

- [ ] `devices/rubens-ubuntu.conf` 与 `distros/ubuntu.sh` 都已创建（上游没有）
- [ ] `PACKAGES_EXTRA` 含 **`wpasupplicant`** 和 `wireless-regdb`
- [ ] 卷标是 `mt6895rubens`
- [ ] 模块数 1608（`build.sh` 会自己编内核；缓存命中时打印 `reusing the cached kernel build`）
- [ ] `debugfs` 能查到 `/usr/sbin/wpa_supplicant`

boot.img：

- [ ] ramdisk 是 **LZ4 legacy**（魔数 `02214c18`）
- [ ] ramdisk < 4 MiB
- [ ] ramdisk 含 `/lib/firmware/arm/mali/arch10.8/mali_csffw.bin` 和 `/lib/firmware/conninfra.cfg`
- [ ] `/init` 里 `basename` 已替换为 `${b##*/}`
- [ ] `/init` 有 `kill_old_shells`
- [ ] `boot_signature_size` @1580 == `0x1000`
- [ ] `os_version ≥ 12.0.0`（anti-rollback）

刷入后：

- [ ] `resize2fs` 扩容到 223 GB
- [ ] `nmcli ... ifname wlan0` 连上 WiFi
- [ ] `dmesg | grep panthor` 显示 `Firmware git sha`
- [ ] `/dev/dri/` 有 `card0` `card1` `renderD128`
- [ ] `ip_forward=1` 已持久化

---

## 11. 参考

| 资源 | 链接 |
|---|---|
| 内核源码 | https://github.com/MT6895-Mainline/linux （`port/rubens-clean`） |
| rootfs 构建器 | https://github.com/MT6895-Mainline/rootfs |
| 作者视频教程 | B 站 BV1YZYe6TE3T |
| Docker 内核检查器 | https://github.com/moby/moby/blob/master/contrib/check-config.sh |
| 清华 Ubuntu 镜像 | https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports |
| MediaTek UFS 驱动 | `drivers/ufs/host/ufs-mediatek.c` |
| Mali panthor 驱动 | `drivers/gpu/drm/panthor/` |
| 设备树 | `arch/arm64/boot/dts/mediatek/mt6895-xiaomi-rubens.dts` |

---

## 附：本文档验证过的确切版本

```
主机        Ubuntu 26.04.1 LTS / 16 核
clang       21.1.8 (Ubuntu 6ubuntu1)
LLD         21.1.8
mmdebstrap  1.5.7
lz4         1.10.0  (/usr/bin/lz4)
GNU Make    4.4.1
内核基线    80d38270aa  (MT6895-Mainline/linux, port/rubens-clean)
内核版本    7.2.0
配置来源    configs/kernel.config
image_size  0x3630000  (54.188 MiB, 余量 64 KiB)
DTB         83,168 字节
模块        1608 个
boot.img    17,956,864 字节
rootfs      464,175,736 字节 (sparse, 1 GiB ext4)
```
