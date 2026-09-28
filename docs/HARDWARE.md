# 硬件支持矩阵 —— Redmi K50 (rubens / MT6895)

在 **Ubuntu 26.04 LTS + Linux 7.2.0** 上的实测结果。

设备：`22041211AC` / codename `rubens` / SoC MT6895 (MT6895Z/TCZA)
原厂系统：HyperOS `OS2.0.10.0.ULNCNXM` / Android 14 / SDK 34

---

## 工作正常的子系统

| 子系统 | 状态 | 驱动 | 设备节点 / 验证方法 |
|---|---|---|---|
| SoC | ✅ | — | `/proc/cpuinfo`，8 核 |
| 内存 | ✅ | — | `MemTotal: 7553952 kB` ⚠️ 见下 |
| **显示** | ✅ | `mediatek-drm` (下游 `mediatek_v2`) | `/dev/dri/card0`，1440×3200 |
| **背光** | ✅ | `panel-l11a` | `/sys/class/backlight/l11a/`，0–4095 |
| **GPU** | ✅ | `panthor` (Mali-G610, CSF) | `/dev/dri/card1` + `renderD128` |
| 帧缓冲控制台 | ✅ | `mediatekdrmfb` | `/dev/fb0` |
| **触摸屏** | ✅ | `fts` (FocalTech) | `/proc/bus/input/devices` → `N: Name="fts"` |
| 音量/电源键 | ✅ | `mtk-kpd`、`mtk-spmi-keys` | `event0`、`event2` |
| 振动马达 | ✅ | `awinic_haptic` | `event1` |
| **存储** | ✅ | `ufs-mediatek` | `/dev/sdc`，238 GiB，88 个分区 |
| **WiFi** | ✅ | `wlan_drv_gen4m` (CONNAC2X2 SOC7_0) | `wlan0`/`wlan1`/`ap0` |
| **蓝牙** | ✅ | `btmtk` + `btif` | `hci0` UP RUNNING |
| **传感器** | ✅ | SCP + `sensorhub` | 5 个 IIO 设备 |
| 环境光（ALS） | ✅ | 经 SCP | `iio:device0` → `xaga-als` |
| 加速度计 | ✅ | 经 SCP | `iio:device1` → `xaga-accel` |
| **充电** | ✅ | `mt6375-charger` | `/sys/class/power_supply/mtk-master-charger/` |
| 电量计 | ✅ | `bq28z610` | `/sys/class/power_supply/bq28z610-0/` |
| Type-C 检测 | ✅ | `mt6375-tcpc` | `/sys/class/power_supply/tcpm-source-psy-.../` |
| SAR / ADC | ✅ | `mt6375-adc`、`mt6363-auxadc`、`mt6368-auxadc` | IIO |
| SCP 协处理器 | ✅ | `MTK_TINYSYS_SCP_SUPPORT` (厂商 RV 版) | `[SCP] recovery success` |
| USB gadget | ✅ | `g_serial` | `/dev/ttyGS0` ↔ 主机 `/dev/ttyACM0` |
| **Docker** | ✅ | overlay2 + nftables + cgroupv2 | `docker info` |

### 传感器完整清单

从 `dmesg | grep sensorhub` 提取（35 个传感器，节选）：

```
type  81  NonUi             vendor xiaomi
type  82  tcs3408_back      vendor AMS
type  84  light_smd         vendor xiaomi
type  90  elliptic_fusion   vendor elliptic
type  91  tcs3701_cct       vendor AMS
type  93  tcs3408_cct       vendor AMS
type  71  lsm6dso_temp      vendor st        ← 温度
type 101  pocket            vendor xiaomi    ← 口袋模式
type 104  screen_down       vendor xiaomi
```

---

## 有问题或未实现的子系统

| 子系统 | 状态 | 症状 | 原因 / 备注 |
|---|---|---|---|
| **AppArmor** | ❌ 有意关闭 | `docker`: `failed to load apparmor profile` | +587 KiB 撑爆 LK 体积预算。见 [PITFALLS §7](PITFALLS.md#7-apparmor-撑爆-lk-体积预算) |
| **无 USB 启动** | ⚠️ 部分 | 拔线开机卡在 WiFi 重试刷屏 | connectivity 时序竞争，未完全定位。见 [PITFALLS §8](PITFALLS.md#8-wifi-上电失败与无-usb-无法启动) |
| **音频输出** | ⚠️ 无声 | `speaker_amp: Container file not loaded` | `tfa98xx` 功放需要容器配置文件 |
| **GPS** | ❌ | `Do GPS driver init failed, ret=-1` | conninfra GPS 子系统未接通 |
| **内存容量** | ⚠️ 偏少 | `MemTotal` 7.2 GiB，硬件 12 GiB | DTB `/memory` 节点只声明 8 GiB |
| **调制解调器** | ❌ | — | 无蜂窝网络（mainline 移植的常见限制） |
| **相机** | ❌ | — | 无 ISP/相机驱动 |
| **MTP/ADB** | ❌ | — | 用的是 CDC-ACM 串口，不是 Android USB 协议 |
| **RTC 时钟** | ⚠️ | 启动时间戳异常 | 无电池后备 RTC 初始化 |
| **Mali 固件时序** | ✅ 已修 | 曾 `probe failed (-2)` | 固件已放入 initramfs |

---

## 已知无害的警告

这些在 `dmesg` 里会出现，但**不影响功能**：

| 警告 | 出现位置 | 说明 |
|---|---|---|
| `ioremap attempted on RAM pfn` | `arch/arm64/mm/ioremap.c:28` | `rubens-earlylog@48180000` 保留内存节点与 `setup_arch()` 已预留范围重叠。作者在 DTS 注释里说明该节点只是"文档化 + 排除出线性映射" |
| `reserved mem: failed to reserve memory for node 'rubens-earlylog@48180000': size 0 MiB` | 同上 | 同上 |
| `consys_co_clock_type_mt6895, failed to get regmap` | `conninfra/platform/mt6895/mt6895.c:188` | `pr_notice` 级别，函数仍返回默认 26M 共时钟方案 |
| `conf_parse: failed to parse 'coex_wmt_epa_elna'` | `conninfra/conf/conninfra_conf.c:511` | 我们的 `conninfra.cfg` 只有 `co_clock_flag=1`，缺这个可选键 |
| `Bluetooth: hci0: READ_SYNC_TRAIN_PARAMS not supported (-56)` | BlueZ | 固件不支持该可选 HCI 命令 |
| `ufshcd-mtk: Failed to get reset control hci_rst: -2` | UFS | 可选 reset 控制器不在 DTB 里；UFS 仍正常工作 |
| `mtk-tphy: Failed to create device link with supplier` | USB PHY | 依赖环，内核已自动处理 |
| `wifi_sigma.cfg` / `txpowerctrl.cfg` 加载失败 | WiFi 驱动 | 可选校准文件，主固件加载成功即可 |
| `g_serial: couldn't find an available UDC` | 早期 | UDC 在 1.2s 时还没注册；之后 gadget 正常 |
| `speaker_amp ... dai_startup fail -22` | ASoC | 见上"音频输出" |

---

## 硬件参数（从设备实测）

| 项目 | 值 |
|---|---|
| SoC | MT6895Z/TCZA (`Hardware name` 从 DTB) |
| GPU | Mali-G610 id `0xa867`，`shader_present=0x130013`，`l2_present=0x1` |
| GPU 时钟 | 218.4 MHz（默认） |
| 屏幕 | 1440×3200，面板 `l11a_38_0a_0a_dsc_cmd_lcm_drv` |
| 背光 | 0–4095 |
| 存储 | UFS `KLUEG8UHGC-B0E1`，238 GiB (256 GB 标称) |
| **userdata 分区** | `/dev/sdc86` = **226 GiB** |
| 电池 | `bq28z610`，标称 4.45 V |
| WiFi MAC | `ac:1e:9e:0a:01:e2` (wlan0) |
| 蓝牙地址 | `AC:1E:9E:0A:01:DF` |
| 分区总数 | 88 个（UFS LUN 2 上） |

### 分区表（内核节点 → GPT 分区名）

```
/dev/sdc1  → misc          /dev/sdc43 → boot_a        /dev/sdc81 → oops
/dev/sdc2  → para          /dev/sdc44 → vendor_boot_a /dev/sdc83 → cust
/dev/sdc13 → nvdata        /dev/sdc56 → boot_b        /dev/sdc86 → userdata
```

**三个对本项目关键的分区**：

| 分区 | 用途 |
|---|---|
| `userdata` (`/dev/sdc86`) | Ubuntu 根文件系统（替换 Android） |
| `nvdata` (`/dev/sdc13`) | WiFi MAC / BT 地址 / 校准数据 → initramfs 提取 |
| `oops` (`/dev/sdc81`) | `pstore/blk` 崩溃日志落盘位置 |

---

## 内存问题详解

```
硬件实际：      12 GiB
内核 MemTotal： 7.2 GiB
```

原因：DTB 的 `/memory` 节点只声明了 8 GiB（并扣除保留内存）。

**修法**（未做）：修改 `mt6895-xiaomi-rubens.dts` 或 `mt6895.dtsi` 的 `/memory` 节点
`reg` 属性为实际的 12 GiB。需要确认物理内存映射布局（可能有空洞）。

**影响**：可用内存少 4.8 GiB，但对当前用途（桌面、Docker）够用。

---

## 参考

- 设备树：`arch/arm64/boot/dts/mediatek/mt6895-xiaomi-rubens.dts`
- 分区布局：`/proc/partitions` 或 bootloader 原厂 scatter 文件
- 硬件识别：`dmesg` 开头 + `Hardware name` 行
