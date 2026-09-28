# 每个文件的来源与生成过程

本仓库**只放从 GitHub 下载不到的文件**。这份文档逐个说明它们的出处，
以及**如何重新生成**——所以它不是"参考文档"，而是可核查的台账。

写这份文档的规则：

- 每一行都必须能指到**具体来源**（某个仓库 + 分支 + commit，或某个设备分区，
  或本仓库的某个生成脚本）。指不到就写"本地原创"并说明怎么来的。
- **不猜**。凡是当时没记录的，宁可标注为未验证，也不编一个出处。

---

## 0. 总表

| # | 文件 | 大小 | 来源 | 生成方式 |
|---|---|---|---|---|
| 1 | `.github/workflows/build.yml` | 47 KB | **本地原创** | 手写；内嵌生成 profile/后端/补丁 |
| 2 | `.gitignore` | 1.2 KB | **本地原创** | 手写 |
| 3 | `README.md` | 10 KB | **本地原创** | 手写 |
| 4 | `docs/BUILD.md` | 42 KB | **本地原创** | 手写，内容来自本机实测 |
| 5 | `docs/PITFALLS.md` | 33 KB | **本地原创** | 手写，13 个坑的复盘 |
| 6 | `docs/SETUP.md` | 11 KB | **本地原创** | 手写 |
| 7 | `docs/HARDWARE.md` | 7.1 KB | **本地原创** | 数据从设备 `dmesg`/`/sys` 采集 |
| 8 | `docs/SOURCES.md` | 本文件 | **本地原创** | 逐文件核查上游仓库与设备得出 |
| 9 | `configs/kernel.config` | 321 KB | **本机内核构建产物** | 见 [§2](#2-configs) |
| 10 | `configs/rubens-ubuntu-overlay.config` | 2.0 KB | **本地原创**（相对上游的差分） | `scripts/extract-overlay.sh` |
| 11 | `configs/mt6895-fixups.config` | 1.2 KB | **本地原创** | 手写 |
| 12 | `patches/0001-rubens-port-fixes.patch` | 29 KB | **本地原创**（5 个文件，来源各异） | 见 [§3](#3-patches) |
| 13 | `ramdisk-proven.lz4` | 729 KB | **本机构建产物** | 见 [§4](#4-ramdisk-provenlz4) |
| 14 | `firmware/`（15 个文件） | 3.2 MB | **上游 initramfs 仓库 + 本设备 vendor 分区** | 见 §5 |
| 15 | `scripts/verify-kernel.sh` | 6.0 KB | **本地原创** | 手写 |
| 16 | `scripts/make-bootimg.sh` | 16 KB | **本地原创** | 手写 |
| 17 | `scripts/flash.sh` | 6.4 KB | **本地原创** | 手写（只打印，不执行） |
| 18 | `scripts/extract-overlay.sh` | 2.8 KB | **本地原创** | 手写 |
| 19 | `scripts/ci-summary.sh` | 3.3 KB | **本地原创** | 手写 |

**没有任何一个文件是从厂商 ROM 里直接搬来的。** 唯一来自设备的是
`firmware/` 里的两个触摸屏文件（`st_fts_L11a.ftb`、`stm_fts_production_limits.csv`），
因为上游 initramfs 仓库里只有 xaga 用的 novatek 版本，rubens 的必须自己取。

### 用到的上游来源一览

| 代号 | 仓库 | 分支 / commit | 用途 |
|---|---|---|---|
| **U1** | `MT6895-Mainline/linux` | `port/rubens-clean` @ `80d38270aa` | 构建基线（内核 + DTB + initramfs 工具） |
| **U2** | `MT6895-Mainline/rootfs` | `main` | rootfs 构建器（运行时克隆） |
| **U3** | `MT6895-Mainline/initramfs` | — | 连接子系统 / GPU / 马达 / 功放固件 |
| **U4** | `rubens-mt6895-mainline/linux` | `7.2-mt6895-xiaomi-rubens` @ `cac2c2fc0` | 旧快照树：板级 DTS 与驱动改动的原始出处 |
| **U5** | 本设备（Redmi K50 / rubens） | — | 触摸屏固件；所有实测数据 |

---

## 1. 仓库自身的文件

`README.md`、`docs/*.md`、`scripts/*.sh`、`.gitignore`、`build.yml` 都是**本地原创**：
在本次移植过程中手写。它们的价值不在"出处"，而在**记录的内容来自实测**：

| 文档 | 内容来源 |
|---|---|
| `docs/BUILD.md` | 每一步都在本机跑过；末尾「验证过的确切版本」是真实版本号 |
| `docs/PITFALLS.md` | 13 个坑都是我实际踩到并定位的，含失败命令的原始报错 |
| `docs/HARDWARE.md` | 设备上 `dmesg` / `/sys` 的输出 |
| `docs/SETUP.md` | 建库与刷机流程，刷机命令在设备上验证过 |

`docs/BUILD.md` §1.1 记录的上游与作者（B 站 BV1YZYe6TE3T）是最初的知识来源，
但文档本身是独立写的。

---

## 2. `configs/`

### 2.1 `kernel.config` — 权威完整配置（321 KB）

**不是**从哪下载的，而是**本机内核构建的产物**。生成链：

```
U1 的 arch/arm64/configs/defconfig          （上游基线）
  + U1 的 arch/arm64/configs/rubens.config  （设备 fragment）
  + configs/mt6895-fixups.config            （本仓库，禁用编不过的其他 SoC 音频）
  + local/rubens-2604-overlay.config        （Ubuntu 26.04 需要的 overlay）
        ↓  scripts/kconfig/merge_config.sh -m
        ↓  make ARCH=arm64 LLVM=1 O=out olddefconfig
        ↓  cp out/.config configs/kernel.config
```

它是**唯一权威**的配置：用它编出的内核已刷入设备并启动，WiFi / 蓝牙 / GPU /
传感器全部工作。`CONFIG_LOCALVERSION=""`，所以 `kernel.release` 是 `7.2.0`
（不带 `+`）——这一点很关键，模块目录名必须与刷入的内核报告的一致。

复现见 `docs/BUILD.md` §3。**不要**用 `extract-overlay.sh` 的输出反过来生成它。

### 2.2 `rubens-ubuntu-overlay.config` — 相对基线的差分（2.0 KB）

由 `scripts/extract-overlay.sh` 生成：拿 `kernel.config` 减去
（`defconfig` + `rubens.config` + fixups）得到 50 项差分。
**只是给人看的**，便于 review「我们到底改了哪 50 项」，不参与构建。

### 2.3 `mt6895-fixups.config` — 本地原创（1.2 KB）

手写。上游 `rubens.config` 里开了其他 SoC 的 MediaTek AFE 音频驱动，
在本树上编译不过；这个文件把它们关掉。注释里逐项写了原因。

---

## 3. `patches/`

### `0001-rubens-port-fixes.patch`（29 KB）

`git format-patch` 的产物，commit `370d716175843cc5aabb075a9255c88fdd3b584c`，
标题 `rubens port fixes on top of 80d38270aa`。它把**旧快照树 U4** 里的
板级改动搬到**新基线 U1 `80d38270aa`** 上。5 个文件来源各不相同：

| 文件 | 改动 | 来源 |
|---|---|---|
| `arch/arm64/boot/dts/mediatek/mt6895-xiaomi-rubens.dts` | +73 行（总 624 行） | **改编自 U4**，见下 |
| `arch/arm64/boot/dts/mediatek/mt6895-xiaomi-xaga.dts` | 1 行 | **本地原创**（交叉验证时的改动） |
| `drivers/misc/rubens-bootlog.c` | +152 行 | **本地原创**（patch 而非 create） |
| `tools/build-rubens-bootimg.sh` | +180 行（新建） | **本地原创** |
| `tools/build-rubens-initramfs-min.sh` | +151 行（新建） | **本地原创** |

#### DTS 的具体来历

U4（`rubens-mt6895-mainline/linux` @ `cac2c2fc0`，分支 `7.2-mt6895-xiaomi-rubens`）
里的 `mt6895-xiaomi-rubens.dts` 有 **1231 行**，是那棵树上的完整板级描述。
新基线 U1 自带的只有 **552 行**。我们的是 **624 行**——也就是说这**不是直接复制**，
而是把 U4 里必要的板级调整**移植**到 U1 的 DTS 上，净改动 74 行。

U4 中承载这些改动的提交：

```
9a96daf11  ARM64: mt6895: Xiaomi Redmi K50 (rubens) mainline bring-up
89edb1c90  drm/mediatek: claim the panel VCI rail and recover from cmdq timeouts
aa888abad  rubens: bring up device tree, FocalTech L11a touch, display and camera fixes
0b44a0116  arm64: dts: mediatek: rubens: drop the xaga LCD backlight
cac2c2fc0  usb: mtu3: drop the bring-up force-VBUS hack (matches 25b88ba084c8)
```

移植过程本身记录在 `local/patch-rubens-dts.diff` 的注释里
（形如 `LOCAL PORT CHANGE (rubens-ubuntu, 2026-09-27)`）。

#### 为什么两个 tools 脚本也是补丁的一部分

它们只存在于**我们的**树里——上游 U1 的 `tools/` 只有
`build-rubens-rootfs.sh`、`build-rubens-vendor-ramdisk.sh`、
`rubens-rootfs-init.sh` 等，**没有** `build-rubens-bootimg.sh`，
也**没有** `build-rubens-initramfs-min.sh`（已用 `git ls-tree 80d38270aa tools/` 核对）。

把它们提交进 git（而不是留在工作树里脏着）还有个副作用是必需的：
`scripts/setlocalversion` 对脏树会追加 `+`，那样 `uname -r` 会变成 `7.2.0+`，
`/lib/modules/7.2.0` 下的模块全部失联。

#### `rubens-bootlog.c` 是 patch 不是 create

补丁里它的行首是 `--- a/drivers/misc/rubens-bootlog.c`（带 index 行），
说明**上游 U1 已经有这个文件**，我们只是改它：让 bootlog 的目标查找在
initmem 被释放后仍然可用（上游在 `4c23dbfdd2` 有另一版修法，这是本地验证过的变体）。

---

## 4. `ramdisk-proven.lz4`

**这是全仓库最不该动的一个文件**，必须是在真机上成功启动过的那份字节。

- sha256 `b143356b498ce8f634a8bc70b2c23ea5d507f12f9a338af006b4132c301914ed`
- 746,200 字节，lz4 **legacy** 格式（魔数 `02214c18`）
- 解开后 1,136,640 字节，99 个 cpio 条目，`/init` 存在

### 生成链（已核实）

```
静态 busybox（musl，aarch64）
  + /init ← local/rubens-initramfs-init-fixed.sh
        ↓  U1 的 tools/build-rubens-initramfs-min.sh
     initramfs.cpio.gz（约 0.63 MiB）
        ↓  /usr/bin/lz4 -l（legacy 模式；conda 的 1.9.4 产出的流内核不认）
     ramdisk-proven.lz4
```

**核实方式**（可复现）：把本文件解出的 `/init` 与
`local/rubens-initramfs-init-fixed.sh` 比对 md5，两者**完全相同**
（`a4c148e3d72f...`）。所以基线就是那个文件。

### `/init` 的来历

`local/rubens-initramfs-init-fixed.sh` 的文件头写明它是
**U1 的 `tools/rubens-rootfs-init.sh` 的本地分支（LOCAL FORK）**，
为 Ubuntu 26.04 移植在 2026-09-27 分叉，改动 4 点（头注释逐条列出）：

1. 去掉上游结尾的 `while :; do wait; sleep 3600; done` —— 这个静态 busybox
   **没有 `wait` applet**，该循环会退化成空转，触发 softlockup，而上游自己的
   bootargs 带 `softlockup_panic=1`，等于静默重启
2. 每一步进度都写 `/dev/kmsg`
3. rootfs 候选按固定顺序尝试，每次 mount 失败都打印 errno
4. 救援 shell **提前**在后台启动

### 已知遗留问题（诚实的说明）

这份 ramdisk 的 `/init` 第 56、99 行**仍然**调用 `basename`：

```sh
printf ' %s' "$(basename "$b")"      # 第 56 行
echo "/dev/$(basename "$b")"         # 第 99 行
```

而这个 busybox 没有 `basename` applet，所以第 99 行会产出 `/dev/`。
它能启动的原因见 `docs/PITFALLS.md`：修复版 `/init` 的候选顺序让
`userdata` 分区的 mount 先成功，因此没走到那条路径。

**结论：不要"顺手"重新生成这个文件。** 它是"验证过的字节"，不是"可重建的产物"。
`scripts/make-bootimg.sh` 会在打包时对 `/init` 做 4 个运行时补丁（PITFALLS §11/§12、
串口 getty、msg 双写），所以仓库里的这份**不需要**预先是修好的版本。

---

## 5. `firmware/`

15 个文件，3.2 MB。**两类来源**：

### 5.1 来自 U3（`MT6895-Mainline/initramfs` 仓库）—— 13 个

| 文件 | 大小 | 用途 |
|---|---|---|
| `WIFI_RAM_CODE_soc7_0_1b_t_1.bin` | 1,203,356 | WiFi 固件 |
| `soc7_0_ram_bt_1b_t_1_hdr.bin` | 599,992 | 连接子系统 BT |
| `soc7_0_ram_wmmcu_1b_t_1_hdr.bin` | 479,640 | 连接子系统 WMMCU |
| `soc7_0_ram_mcu_1b_t_1_hdr.bin` | 147,120 | 连接子系统 MCU |
| `arm/mali/arch10.8/mali_csffw.bin` | 282,624 | **Mali-G610 GPU（内核实际用的路径）** |
| `mali_csffw.bin` | 258,048 | 同上的另一版本，见 5.3 |
| `mali_csffw_reload.bin` | 258,048 | 与上一个**逐字节相同**，见 5.3 |
| `aw8697_haptic.bin` | 3,622 | 震动马达 |
| `aw8697_rtp_1.bin` | 120,000 | 震动马达（RTP 波形） |
| `tfa98xx.cnt` | 3,828 | 功放 |
| `BT_FW.cfg` | 443 | 蓝牙配置 |
| `wifi.cfg` | 1,171 | WiFi 配置 |
| `conninfra.cfg` | 17 | 连接基础设施；内容为 `co_clock_flag=1` |

`conninfra.cfg` 只有 17 字节，是**本地改过的**：原始值让 WiFi 上电失败，
`co_clock_flag=1` 是修好的值（见 PITFALLS §8）。

### 5.2 必须从设备提取 —— 2 个

| 文件 | 大小 | 为什么必须从设备取 |
|---|---|---|
| `st_fts_L11a.ftb` | 130,548 | 触摸屏固件。U3 里只有 xaga 用的 novatek 版本，**rubens 是 FocalTech L11a** |
| `stm_fts_production_limits.csv` | 31,185 | 触摸校准限值，同上一并取自设备 |

提取方式（设备上 `vendor` / `cust` 分区，或从本机 ROM）：

```bash
adb shell su -c 'find /vendor/firmware /vendor/etc/firmware -iname "*fts*" 2>/dev/null'
adb shell su -c 'cat /vendor/firmware/st_fts_L11a.ftb' > st_fts_L11a.ftb
adb shell su -c 'cat /vendor/firmware/stm_fts_production_limits.csv' > stm_fts_production_limits.csv
```

也可以直接把本机 ROM 的 `super.img` 解开取这两个文件。

### 5.3 两个冗余的 mali 文件（说明）

- `mali_csffw.bin` 与 `mali_csffw_reload.bin` 的 md5 **相同**
  （`ddef4ef1802903d3f54259da07605229`），是同一份字节的两个名字。
- 它们的 md5 与 `arm/mali/arch10.8/mali_csffw.bin`
  （`cd95e83312eec65ff523025b52badb4a`）**不同**。
- 内核只认 `arm/mali/arch10.8/mali_csffw.bin`
  （`drivers/gpu/drm/panthor/panthor_fw.c` 的 `MODULE_FIRMWARE`）。

所以那两个顶层文件是随上游固件集一起带过来的**历史冗余**，删掉不影响功能，
保留只是为了让 `firmware/` 与 U3 的固件集保持一致、便于比对。

### 5.4 运行时自动生成、不需要放进仓库的

- `mediatek/mt6895/WIFI`（WiFi 校准 + MAC）—— 启动时 initramfs 从 `nvdata`
  分区复制
- `mediatek/mt6895/BT_Addr`（蓝牙 MAC）—— 同上
- `regulatory.db` / `regulatory.db.p7s`（管制域）—— Ubuntu 的
  `wireless-regdb` 包提供，rootfs 构建时自动就位

### 5.5 版权与分发

这些是**厂商专有 blob**，任何公开仓库都不会分发。放进本仓库是为了让 CI
能构建出可直接刷入的镜像。**建议把仓库设为 private**；如果公开，
请自行确认这样做的合规性。上游 U3 提供 `tools/extract-firmware.sh`，
支持 `--from-rootfs`（从已能启动 mainline 的设备打包 `/lib/firmware`）和
`--from-partitions`（从原厂分区分块导出）。

---

## 6. 更新台账时要注意的

改任何文件后请回来更新本表，并遵守两条纪律：

1. **别把"可重建产物"和"验证过的字节"混为一谈。**
   `configs/kernel.config` 可以重新生成（同一个基线 + 同一份 overlay 就得到
   同一个配置）；`ramdisk-proven.lz4` **不行**——它是"在真机上启动过"这个
   事实的载体，重新压一份哪怕内容相同，也不再是同一份被验证过的字节。
2. **上游改了就要重新核对来源。** 本文档里 U1 的基线是 `80d38270aa`、
   U4 是 `cac2c2fc0`。基线一变，`kernel.config` 的差分、DTS 的移植、
   `verify-kernel.sh` 里的 `EXPECTED_RELEASE` 都要重查。
