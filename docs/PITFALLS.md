# 踩坑清单 —— Redmi K50 (rubens/MT6895) Ubuntu 26.04 移植

按**排查耗时**排序。每一条都包含：症状 → 根因 → 修法 → 如何验证。

> **强烈建议动手前通读一遍。** 这些坑合计消耗了 20+ 小时，
> 其中一半的时间浪费在"在错误的地方找证据"。

---

## 目录

| # | 主题 | 一句话 |
|---|---|---|
| [1](#1-mtk_cmdq-与-mtk_cmdq_mbox_ext-符号冲突) | `MTK_CMDQ` 符号冲突 | 两套驱动导出同名符号，必须二选一 |
| [2](#2-两套-scp-实现冲突) | 两套 SCP 实现冲突 | 同上，且函数签名都不同 |
| [3](#3-dtb-并行构建竞争) | DTB 并行构建竞争 | `make Image modules` 会失败，必须先 `make dtbs` |
| [4](#4-kernelrelease-多出--后缀) | `kernel.release` 变成 `7.2.0+` | 脏工作区导致 1608 个模块全部失配 |
| [5](#5-networkmanager-没有无线能力) | NM 无法使用无线 | `PACKAGES_EXTRA` 漏了 `wpasupplicant` |
| [6](#6-gpu-固件加载时序) | GPU 固件加载时序 | 内建驱动 probe 早于 rootfs 挂载 |
| [7](#7-apparmor-撑爆-lk-体积预算) | AppArmor 撑爆预算 | `select` 强拉依赖，+587 KiB 无法接受 |
| [8](#8-wifi-上电失败与无-usb-无法启动) | WiFi 上电失败 | `conninfra.cfg` 时序 + 驱动的重试缺陷 |
| [9](#9-mt6895-firstboot-从未运行) | 首次启动服务未启用 | 镜像里缺 `sysinit.target.wants` 符号链接 |
| [10](#10-ramdisk-必须是-lz4-legacy) | ramdisk 格式 | 必须是 LZ4 **legacy**，现代 frame 格式内核不认 |
| [11](#11-busybox-没有-basename) | busybox 缺 applet | 挂载根分区失败，曾导致 19 次启动失败 |
| [12](#12-switch_root-不清理后台进程) | switch_root 的语义 | 只替换 PID 1，不清理其子进程 → 永久刷屏 |
| [13](#13-在错误的地方找证据) | **方法论教训** | 5 次误判的复盘 |

---

## 1. `MTK_CMDQ` 与 `MTK_CMDQ_MBOX_EXT` 符号冲突

### 症状

编译到最后阶段失败，两种表现取决于配置：

```
# 情况 A：MTK_CMDQ=m, MTK_CMDQ_MBOX_EXT=y
ERROR: modpost: drivers/soc/mediatek/mtk-cmdq-helper: 'cmdq_pkt_wfe' exported twice.
       Previous export was in vmlinux

# 情况 B：MTK_CMDQ=y, MTK_CMDQ_MBOX_EXT=y
ld.lld: error: duplicate symbol: cmdq_mbox_create
```

### 根因

**两个互斥的实现导出同一组符号**：

| 文件 | 配置项 | 导出符号数 |
|---|---|---|
| `drivers/soc/mediatek/mtk-cmdq-helper.c` | `CONFIG_MTK_CMDQ` | 20 |
| `drivers/misc/mediatek/cmdq/mailbox/mtk-cmdq-helper-ext.c` | `CONFIG_MTK_CMDQ_MBOX_EXT` | 20+ |

**交集 14 个**：`cmdq_mbox_create`、`cmdq_mbox_destroy`、`cmdq_pkt_create`、
`cmdq_pkt_destroy`、`cmdq_pkt_write`、`cmdq_pkt_mem_move`、`cmdq_pkt_logic_command`、
`cmdq_pkt_poll_addr`、`cmdq_pkt_poll`、`cmdq_pkt_wfe`、`cmdq_pkt_acquire_event`、
`cmdq_pkt_clear_event`、`cmdq_pkt_set_event`、`cmdq_pkt_eoc`

```bash
# 自己验证交集
comm -12 \
  <(grep -oE 'EXPORT_SYMBOL[A-Z_]*\(([a-z_]+)\)' drivers/soc/mediatek/mtk-cmdq-helper.c |
    sed 's/.*(\(.*\))/\1/' | sort -u) \
  <(grep -oE 'EXPORT_SYMBOL[A-Z_]*\(([a-z_]+)\)' \
    drivers/misc/mediatek/cmdq/mailbox/mtk-cmdq-helper-ext.c |
    sed 's/.*(\(.*\))/\1/' | sort -u)
```

**三种组合的结果**：

| `MTK_CMDQ` | `MBOX_EXT` | 结果 |
|---|---|---|
| `=m` | `=y` | ❌ modpost：模块与 vmlinux 重复导出 |
| `=y` | `=y` | ❌ ld.lld：两个内置实现重复符号 |
| **`=n`** | **`=y`** | ✅ **唯一可行** |

### 修法

```
# CONFIG_MTK_CMDQ is not set
CONFIG_MTK_CMDQ_MBOX=y
CONFIG_MTK_CMDQ_MBOX_EXT=y
```

### 为什么可以安全关闭 `MTK_CMDQ`

检查所有引用：

```bash
grep -rn 'MTK_CMDQ' --include=Kconfig --include=Makefile drivers/
```

输出只有三处：

1. `drivers/soc/mediatek/Makefile:2` —— 编译那个 helper
2. `drivers/media/platform/mediatek/mdp3/Kconfig:9` —— `depends on MTK_CMDQ`（**MDP3 不用**）
3. `drivers/soc/mediatek/Kconfig:98` —— `depends on MTK_CMDQ || MTK_CMDQ=n`（**`=n` 同样满足**）

而 MTK 扩展版**已提供全部符号**（含上游版没有的 `cmdq_pkt_assign_command` 等）。

> 旧配置能工作正是因为它设了 `MTK_CMDQ=n` —— 但当时的原因和现在**是同一个**，
> 只是表现出来是模块冲突而非链接冲突。

---

## 2. 两套 SCP 实现冲突

### 症状

```
ld.lld: error: duplicate symbol: scp_ipi_send
```

### 根因

**同名符号，不同签名**：

| 实现 | 文件 | 签名 |
|---|---|---|
| 厂商 RV 版 | `drivers/misc/mediatek/scp/rv/scp_wrapper_ipi.c` | `scp_ipi_send(enum ipi_id id, void *buf, ...)` |
| 上游 remoteproc 版 | `drivers/remoteproc/mtk_scp_ipi.c` | `scp_ipi_send(struct mtk_scp *scp, u32 id, ...)` |

配置关系：

```
CONFIG_MTK_TINYSYS_SCP_SUPPORT=y   → 厂商版（bool，无法模块化）
CONFIG_MTK_SCP=y                   → 上游版（tristate，depends on MTK_SCP）
CONFIG_RPMSG_MTK_SCP=y             → 上游版的 rpmsg 部分（depends on MTK_SCP）
```

### 修法

**关掉上游版**：

```
CONFIG_MTK_TINYSYS_SCP_SUPPORT=y
# CONFIG_MTK_SCP is not set
# CONFIG_RPMSG_MTK_SCP is not set
CONFIG_MTK_SENSORHUB=y
```

**为什么保留厂商版**：传感器 hub 依赖它。验证：

```bash
# sensorhub 源码用的都是厂商版符号
grep -rhoE '\bscp_[a-z_]+' drivers/misc/mediatek/sensor/2.0/sensorhub/*.c | sort -u
#   输出: scp_ipidev, scp_sensor_ready, scp_platform_ready, scp_timestamp,
#         scp_archcounter, scp_wdt_reset ...（都是厂商版的）
```

上游版的唯一消费者是 MDP3 和 SCP 版 vcodec，都不用；
且 `drivers/media/.../vcodec/Kconfig` 接受 `MTK_SCP || !MTK_SCP`。

---

## 3. DTB 并行构建竞争

### 症状

```
***
*** Configuration file ".config" not found!
***
make[6]: *** [Makefile:892：.config] 错误 1
make[5]: *** [../arch/arm64/kernel/Makefile:104：arch/arm64/boot/dts/mediatek/mt6895-xiaomi-rubens.dtb] 错误 2
```

奇怪之处：`.config` **明明存在**，而且**单独跑 `make dtbs` 能成功**。

### 根因

`arch/arm64/kernel/Makefile` 里有个非标准规则，把板级 DTB 打包成 `.o` 内嵌进 Image：

```makefile
ifeq ($(CONFIG_XIAOMI_RUBENS),y)
board-dtb := arch/arm64/boot/dts/mediatek/mt6895-xiaomi-rubens.dtb
obj-$(CONFIG_OF) += rubens-dtb.o
$(obj)/rubens-dtb.o: $(board-dtb) FORCE
	$(call if_changed,objcopy)
endif

$(board-dtb):
	$(Q)$(MAKE) -C $(srctree) O=$(objtree) $@      # ← 递归调用子 make
```

并行构建 `make Image modules` 时，这个递归子 make 可能在**配置完全就绪之前**启动，
于是它看不到 `.config`。

### 修法

**分两步编译**：

```bash
# 步骤 1：单独构建 DTB（约 1 分钟）
make -C . O=out ARCH=arm64 LLVM=1 dtbs

# 步骤 2：构建内核与模块
LOCALVERSION= make -C . O=out ARCH=arm64 LLVM=1 -j"$(nproc)" Image modules
```

**验证**：`out/arch/arm64/boot/dts/mediatek/mt6895-xiaomi-rubens.dtb` 已生成（83,168 字节）。

---

## 4. `kernel.release` 多出 `+` 后缀

### 症状

```
$ cat out/include/config/kernel.release
7.2.0+
```

后果：`uname -r` 返回 `7.2.0+`，而 rootfs 里模块在 `/lib/modules/7.2.0` ——
**全部 1608 个模块都无法加载**（`modprobe` 报 `Module not found`）。

### 根因

`scripts/setlocalversion` 的逻辑：

```sh
if [ -n "${count}" ]; then ... fi
# If the variable LOCALVERSION is not set, append a plus sign if the repository
# is not in a clean annotated or signed tagged state
elif [ "${LOCALVERSION+set}" != "set" ]; then
    scm_version="$(scm_version --short)"     # ← 脏工作区时返回 "+"
fi
```

关键点：**`LOCALVERSION` 未设置时**，脏工作区会得到 `+`。
如果 `LOCALVERSION` **被设置（哪怕设为空字符串）**，就跳过这段逻辑。

而"脏"的判定是：

```sh
git --no-optional-locks status -uno --porcelain 2>/dev/null || git diff-index --name-only HEAD
```

我们有 3 个文件的本地改动（DTS ×2、bootlog），所以工作区是脏的。

### 修法（两种，都要做）

**① 提交本地改动**（让工作区干净）

```bash
cd kernel
git add -A
git -c user.name="port" -c user.email="port@localhost" commit -m "rubens port fixes"
git log --oneline -1
```

这同时也让移植修复进入版本历史 —— 是更好的工程实践。

**② 编译时显式传 `LOCALVERSION=`**

```bash
LOCALVERSION= make -C . O=out ARCH=arm64 LLVM=1 -j"$(nproc)" Image modules
```

**还要注意**：`kernel.release` 是**缓存文件**。改完工作区状态后，`make` 可能认为它
没变而不重新生成。需要强制：

```bash
rm -f out/include/config/kernel.release \
      out/include/generated/utsrelease.h \
      out/include/generated/compile.h
LOCALVERSION= make -C . O=out ARCH=arm64 LLVM=1 Image modules
```

### 验证

```bash
cat out/include/config/kernel.release        # 必须是 7.2.0
grep -oE 'UTS_RELEASE "[^"]*"' out/include/generated/utsrelease.h
strings out/arch/arm64/boot/Image | grep -m1 'Linux version'
#   期望: Linux version 7.2.0 (ubuntu@ubuntu) ...
```

---

## 5. NetworkManager 没有无线能力

### 症状

```
$ nmcli device status
wlan0:wifi:unavailable:                    ← 不是 disconnected，是 unavailable
$ nmcli device wifi list
SSID  SIGNAL  SECURITY                     ← 空表
$ nmcli device wifi rescan
Error: Scanning not allowed while unavailable.
```

**而 `iw` 却能正常扫描**（所以驱动没问题）：

```
$ iw dev wlan0 scan | grep SSID
	SSID: midea_db_1217
	SSID: HUAWEI_1DEF
```

NetworkManager 的日志揭示真因：

```
device (wlan0): Couldn't initialize supplicant interface:
                Failed to D-Bus activate wpa_supplicant service
device (wlan0): supplicant interface keeps failing, giving up
```

### 根因

**`wpasupplicant` 包没装。**

```
$ dpkg -l | grep -i wpa
（无输出）
$ ls /sbin/wpa_supplicant /usr/sbin/wpa_supplicant
ls: cannot access ...: No such file or directory
```

关键陷阱：**`network-manager` 包不硬依赖 `wpasupplicant`**（Ubuntu 把它列为可选）。
所以只装 NM 不会自动带上它，而**没有 supplicant 的 NM 对任何无线网络都无能为力** ——
无论 2.4G/5G、无论加密还是开放。

### 修法

在 rootfs 构建配置里加上：

```bash
# devices/rubens-ubuntu.conf
PACKAGES_EXTRA="network-manager bluez modemmanager iio-sensor-proxy \
                alsa-ucm-conf alsa-utils usbutils pciutils iproute2 \
                ethtool iw rfkill wireless-regdb wpasupplicant \    # ← 加这个
                less nano zstd e2fsprogs dosfstools \
                curl wget htop tmux ca-certificates apt-utils"
```

然后重建 rootfs。

### 验证

```bash
# 镜像里
debugfs -R "stat /usr/sbin/wpa_supplicant" /tmp/rootfs.raw | grep Inode
debugfs -R "ls /usr/share/dbus-1/system-services" /tmp/rootfs.raw | grep wpa

# 设备上
systemctl status wpa_supplicant --no-pager | head -3   # 应 active (running)
nmcli device status                                     # wlan0 应是 disconnected
nmcli device wifi list                                  # 应列出真实 AP
```

### 附带发现的第二个坑：NM 会选错虚拟接口

连上之后如果你不指定接口，NM 可能把连接建到 **`ap0`**（AP 模式虚拟接口）上：

```
$ nmcli device status
ap0:connecting (configuring):Xiaomi 14     ← 建到 ap0 上了
$ nmcli device wifi connect "Xiaomi 14" password "..."
Error: Connection activation failed: The Wi-Fi network could not be found.
```

**必须显式指定 `ifname wlan0`**：

```bash
nmcli device wifi connect "SSID" password "PW" ifname wlan0
```

MTK 驱动暴露 `wlan0`/`wlan1`/`ap0` 三个 VIF，NM 会猜错。

---

## 6. GPU 固件加载时序

### 症状

```
$ dmesg | grep panthor
panthor 13000000.gpu: [drm] Mali-G610 id 0xa867 ...
panthor 13000000.gpu: Direct firmware load for
                      arm/mali/arch10.8/mali_csffw.bin failed with error -2
panthor 13000000.gpu: [drm] *ERROR* Failed to load firmware image 'mali_csffw.bin'
panthor 13000000.gpu: probe with driver panthor failed with error -2

$ ls /dev/dri/
card0                    ← 只有显示，没有 GPU
```

### 排查过程（值得学习）

```bash
# ① 固件存在吗？
ls -la /lib/firmware/arm/mali/arch10.8/mali_csffw.bin
#   → 存在，282624 字节 ✅

# ② 内容对吗？
md5sum /lib/firmware/arm/mali/arch10.8/mali_csffw.bin
#   → 与固件源一致 ✅

# ③ 路径对吗？
grep MODULE_FIRMWARE drivers/gpu/drm/panthor/panthor_fw.c
#   → MODULE_FIRMWARE("arm/mali/arch10.8/mali_csffw.bin") 完全匹配 ✅

# ④ 硬件在吗？
dmesg | grep 'Mali-G610'
#   → Mali-G610 id 0xa867, shader_present=0x130013 ✅

# ⑤ 决定性实验：手动重新绑定设备
dmesg -C
echo 13000000.gpu > /sys/bus/platform/drivers/panthor/unbind
echo 13000000.gpu > /sys/bus/platform/drivers/panthor/bind
dmesg | grep panthor
#   → Firmware git sha: 95a25d71...   ← 成功了！
#   → [drm] Initialized panthor 1.8.0 for 13000000.gpu on minor 1
#   → /dev/dri/card1 和 renderD128 出现
```

**⑤ 证明：文件没错、路径没错、硬件没错 —— 只是驱动问得太早。**

### 根因

```
CONFIG_DRM_PANTHOR=y          ← 内建（不是模块）
```

内建驱动在 **1.42 秒** probe，而 rootfs 在 **3.3 秒**才挂载：

```
[1.420438] panthor: Direct firmware load for ... failed (-2)   ← 找不到文件
[3.21xxx]  initramfs: mount userdata                            ← rootfs 此时才挂载
[3.3xxx]   initramfs: switch_root
```

内建驱动只能看到 **initramfs** 的内容，看不到磁盘。

### 修法：把固件放进 initramfs

```bash
# 打包 boot.img 时，注入到 ramdisk
mkdir -p ramdisk/lib/firmware/arm/mali/arch10.8
install -m 0644 firmware/arm/mali/arch10.8/mali_csffw.bin \
        ramdisk/lib/firmware/arm/mali/arch10.8/mali_csffw.bin
```

**为什么不用 `CONFIG_DRM_PANTHOR=m`**：

| | 改 ramdisk | 改内核配置 |
|---|---|---|
| 内核重编 | ❌ 不需要 | ✅ 需要（15 分钟） |
| Image 尺寸 | 不变 | 变小约 300 KB |
| 副作用 | 无 | 需重新验证尺寸预算 |

**ramdisk 尺寸代价**：746,200 → 819,879 字节（+73 KB 压缩后），
预算 4 MiB，占用率从 18% 升到 20%。完全可接受。

### 验证

```bash
dmesg | grep -iE 'panthor.*Firmware git sha|Initialized panthor'
#   期望两行都在，且【没有】'failed with error -2'
ls -l /dev/dri/
#   期望: card0  card1  renderD128
```

---

## 7. AppArmor 撑爆 LK 体积预算

### 症状

加 AppArmor 后编译成功，但：

```
image_size = 0x36c0000  (54.750 MiB)
预算       = 0x3640000  (54.250 MiB)
余量       = -524288 字节  ← 超了 512 KiB
```

### 根因

AppArmor 的 Kconfig：

```
config SECURITY_APPARMOR
	bool "AppArmor support"
	depends on SECURITY && NET
	select AUDIT
	select SECURITY_PATH       ← 强拉！
	select SECURITYFS
	select SECURITY_NETWORK    ← 强拉！
```

**`select` 是强依赖，无法通过配置绕过。**
而 `SECURITY_NETWORK` / `SECURITY_PATH` 会把 LSM 钩子织进**整个网络栈和文件系统栈** ——
这才是 587 KiB 的真正来源，不是 AppArmor 自身代码。

**而且还有个陷阱**：关掉 `CONFIG_SECURITY_APPARMOR` **不会**自动收回被 `select` 的项。
`olddefconfig` 会保留它们为 `=y`（因为已被显式写入）。必须显式关闭：

```
# CONFIG_SECURITY_APPARMOR is not set
# CONFIG_SECURITY_NETWORK is not set      ← 必须显式关，否则省不下空间
# CONFIG_SECURITY_PATH is not set
CONFIG_LSM="landlock,lockdown,yama,loadpin,safesetid,ipe,bpf"   # 去掉 apparmor
```

### 最终决策：回退

| 方案 | `image_size` | 判定 |
|---|---|---|
| 无 AppArmor | `0x3630000` (54.188 MiB) | ✅ 余量 64 KiB（已实测启动） |
| 有 AppArmor | `0x36c0000` (54.750 MiB) | ❌ 超出唯一验证过的边界 |
| 作者验证上限 | `0x3640000` (54.250 MiB) | — |
| 已知失效点 | `0x3820000` (56.125 MiB) | 复位循环 |

**结论：能启动 > 有 LSM 隔离。**

### 代价

Docker 启动时会打印：

```
WARN failed to load apparmor profile docker-default
```

**容器照常运行**，只是没有 LSM 限制。用 `moby/contrib/check-config.sh` 检查会看到
`CONFIG_SECURITY_APPARMOR: missing` —— 这是**预期且已知**的。

### 想要 AppArmor 的话怎么办

需要从别处省出 587 KiB。当前能动的候选：

| 项 | 类型 | 能否模块化 |
|---|---|---|
| `CONFIG_MTK_TINYSYS_SCP_SUPPORT` | bool | ❌ |
| `CONFIG_MTK_SENSORHUB` | bool | ❌ |
| `CONFIG_SND_SOC_MT6895` 系列 | tristate | ✅ 改为 `=m` |
| `CONFIG_MTK_COMBO` | tristate | ✅ 但会破坏 WiFi 时序优势 |

---

## 8. WiFi 上电失败与无 USB 无法启动

### 症状

**不插 USB 开机** → 屏幕刷屏，永不进桌面：

```
[   17.871257] btmtk: BT_Addr not ready yet (-2), retrying
[   17.954833] Direct firmware load for mediatek/mt6895/WIFI failed (-2)
[   17.967202] XAGA-NVRAM: not available yet (-2), retrying
... 每 250ms 一轮
[   19.446963] wlanProbe: probe failed, reason:3
[   19.480036] [WIFI-FW] mtk_wcn_wlan_func_ctrl[E]: WiFi on/off op fail, g_data=-1
[   19.491825] XAGA-NVRAM: WiFi power-on failed, retry 1/3
```

**插上 USB** → 继续输出，然后进桌面。

### 这是**两个独立问题**，不是一个

#### 问题 A：`conninfra.cfg` 加载时序（**已修复**）

驱动源码里的重试逻辑**有缺陷**：

```c
// drivers/misc/mediatek/connectivity/conninfra/conf/conninfra_conf.c
static int platform_request_firmware(char *patch_name, osal_firmware **ppPatch)
{
	do {
		ret = request_firmware((const struct firmware **)&fw, patch_name, NULL);
		if (ret == -EAGAIN) {                    // ← 只对 -EAGAIN 重试
			pr_err("failed to open or read!(%s), retry again!\n", patch_name);
			osal_sleep_ms(100);
		}
	} while (ret == -EAGAIN);
	if (ret != 0) {
		pr_err("failed to open or read!(%s)\n", patch_name);
		return -1;                               // ← -ENOENT 直接放弃，永不重试
	}
	...
}
```

**文件不存在返回 `-ENOENT (-2)`，不是 `-EAGAIN`** → 循环立即退出 → 永不重试。

而 `conninfra_conf_init()` 在 **`conninfra_dev.c:641`** 被调用 ——
那是**内建驱动早期初始化（1.36 秒）**，rootfs 还没挂载：

```
[1.365030] Direct firmware load for conninfra.cfg failed with error -2
[1.365051] conninfra@(platform_request_firmware:538) failed to open or read!(conninfra.cfg)
```

于是 `cfg_exist = 0` **永久保持**，后续每次上电都：

```
consys_co_clock_type_mt6895: [consys_co_clock_type_mt6895] Get conf fail   ← 刷屏
```

**修法**：把 `conninfra.cfg`（**只有 17 字节**，内容是 `co_clock_flag=1`）
也放进 initramfs：

```bash
install -m 0644 firmware/conninfra.cfg ramdisk/lib/firmware/conninfra.cfg
```

**验证修复生效**：

```bash
dmesg | grep -cE 'Get conf fail'        # 期望 0（之前几百条）
dmesg | grep 'conf_parse'               # 有输出说明配置文件被读取解析了
```

#### 问题 B：WiFi 首次上电失败（**未完全解决**）

即使问题 A 修复了，`wlanProbe: probe failed, reason:3` 仍会出现，约 3 秒后重试成功。

**驱动自己的注释说明了设计意图**：

```c
/*
 * Chip power-on can fail on marginal boots (the VCN33 input rails sag when
 * the battery is low).  wlanProbe then bails out at glBusInit before any
 * netdev exists ...
 */
#define XAGA_NVRAM_RETRY_MS    250
#define XAGA_NVRAM_MAX_RETRIES 480    /* ~120s */
#define XAGA_PWRON_RETRY_MS    3000
#define XAGA_PWRON_MAX_RETRIES 3
```

**但供电已排除**：

```
POWER_SUPPLY_NAME=bq28z610-0
POWER_SUPPLY_HEALTH=Good
POWER_SUPPLY_CAPACITY=100
POWER_SUPPLY_VOLTAGE_NOW=4454000        ← 4.45 V，非常健康
```

**所以是时序竞争，不是供电不足。** 未完全定位到具体依赖。

**当前的实用结论**：插 USB 启动是可行的日常用法（设备功能完全正常）。

**若要继续深挖，建议方向**：

1. 把 connectivity 驱动改成模块（`CONFIG_MTK_COMBO=m` / `CONFIG_CFG80211=m` / `CONFIG_BT=m`），
   让它们等 rootfs 挂载后 probe —— **一次性消除所有固件时序问题**
2. 检查 USB 插入到底改变了什么（`mt6375-chg` 的 VBUS 检测 → conninfra 上电路径？）
3. 降低 `XAGA_NVRAM_MAX_RETRIES`（480 → 20）至少让刷屏在 5 秒内停止

### 一个容易误判的点

那份 pstore 里的 `console-ramoops-0` 是**旧记录**。判据是它里面的：

```
RUBENS-DTB: overriding LK FDT with embedded mt6895-xiaomi-rubens.dtb (80009 bytes)
```

**80,009 字节是旧 DTB**，加入 SCP/传感器节点后是 **83,168 字节**。
看到旧数值就说明这份记录来自旧内核。

**不要拿 pstore 里的旧记录当当前状态的证据。** 判断方法：
对比 `RUBENS-DTB` 行里的字节数，或看 `Linux version` 里的编译时间。

---

## 9. `mt6895-firstboot` 从未运行

### 症状

每次重刷 rootfs 后，根文件系统都是 **1 GiB**，需要手动扩容：

```
$ df -h /
/dev/sdc86      974M  442M  465M  49% /
```

而且服务状态异常：

```
$ systemctl status mt6895-firstboot --no-pager
○ mt6895-firstboot.service - MT6895-Mainline first boot setup
     Loaded: loaded (/etc/systemd/system/mt6895-firstboot.service; disabled; ...)
     Active: inactive (dead)
$ ls /var/lib/mt6895-firstboot-done
ls: cannot access ...: No such file or directory
```

### 根因

**镜像里缺少启用符号链接。** 单元文件本身存在（394 字节），脚本也存在（810 字节），
但 `sysinit.target.wants/` 里没有指向它的链接 —— 构建时漏了 `systemctl enable`。

```bash
# 镜像里 sysinit.target.wants 只有 6 个链接，没有 mt6895-firstboot
debugfs -R 'ls /etc/systemd/system/sysinit.target.wants' /tmp/rootfs.raw
```

### 临时修法（设备上）

```bash
resize2fs $(findmnt -no SOURCE /)     # ext4 支持在线扩容
df -h /
```

### 永久修法

在 rootfs 构建流程里加一条 `systemctl enable mt6895-firstboot`，
或在 `PACKAGES_EXTRA` 之后加一个 chroot 步骤：

```bash
chroot "$ROOTFS" systemctl enable mt6895-firstboot.service
```

---

## 10. ramdisk 必须是 LZ4 legacy

### 症状

```
Initramfs unpacking failed: Decoding failed
```

然后内核 panic，设备复位循环。

### 根因

内核的 initramfs 解压器按**魔数**分派：

```c
// lib/decompress.c
static const struct compress_format compressed_formats[] = {
	{ {0x1f, 0x8b, 0x08, 0x00}, "gzip" },      // ← gzip 实际不工作（见下）
	{ {0x02, 0x21, 0x4c, 0x18}, "lz4"  },      // ← LZ4 legacy
	...
};
```

**必须用 LZ4 legacy 格式**，魔数 `02 21 4c 18`：

```bash
# ✅ 正确：-l 表示 legacy，-9 是压缩级别
/usr/bin/lz4 -l -9 -f ramdisk.cpio ramdisk.lz4
xxd -p -l4 ramdisk.lz4
#   期望: 02214c18
```

### 两个坑

**① 不要用 conda 的 lz4**。`lz4 v1.9.4` 在 legacy 模式下产出的流内核不认：

```bash
$ command -v lz4
/home/ubuntu/miniconda3/bin/lz4      # ← 1.9.4，不要用
$ /usr/bin/lz4 --version
*** lz4 v1.10.0 ... ***              # ← 用这个
```

**② legacy 格式的结构容易误读**：

```
[4 字节魔数][4 字节块长度][数据]... [4 字节块长度][数据]
```

魔数后面那 4 字节**就是第一个块的长度**，**不是**现代 frame 格式的 FLG/BD 字段。
（我一度按 frame 格式解读，得出"1 MB 块 vs 4 KB 块"的错误结论，浪费了大量时间。）

**用 Python 正确解析**：

```python
import struct
d = open('ramdisk.lz4','rb').read()
assert d[:4] == bytes.fromhex('02214c18'), "不是 LZ4 legacy"
off = 4
while off + 4 <= len(d):
    sz = struct.unpack_from('<I', d, off)[0]
    off += 4
    if sz == 0: break
    off += sz
print(f"解析结束于 {off} / 文件 {len(d)}")
```

### 验证

```bash
# 内核会打印
dmesg | grep -iE 'initramfs|Decoding'
#   失败: "Initramfs unpacking failed: Decoding failed"
#   成功: 无此错误，且 initramfs /init 的 msg() 输出出现
```

---

## 11. busybox 没有 `basename`

### 症状

启动失败，落到 initramfs 的 rescue shell。日志：

```
rubens-initramfs: trying userdata (/dev/)              ← 注意是 /dev/ ，不是 /dev/sdc86
rubens-initramfs: mount of /dev/ (userdata) failed
rubens-initramfs: no bootable rootfs, rescue shells only
```

而且在 rescue shell 里执行任何用到 `basename` 的命令都失败：

```
~ # basename /dev/sdc86
sh: basename: not found
~ # echo $?
127
```

### 根因

initramfs 里的 `/init` 用 `basename` 取设备名：

```sh
find_part_by_name() {
	want="$1"
	for b in /sys/class/block/*; do
		[ -f "$b/partition" ] || continue
		case "$(cat $b/uevent 2>/dev/null)" in
		*PARTNAME="$want"*)
			echo "/dev/$(basename "$b")"       # ← busybox 没有这个 applet
			return 0
			;;
		esac
	done
	return 1
}
```

**`basename` 不是 busybox 内建 applet**（这份精简 busybox 里没有）。
命令替换返回空字符串 → 函数返回 `/dev/` → `mount -t ext4 /dev/ /mnt/root` 必然失败。

### 修法

**用纯 shell 参数展开，不依赖任何 applet**：

```sh
echo "/dev/${b##*/}"       # ✅
```

### 验证

**修复后不要说"应该好了"** —— 在设备的 rescue shell 里实测：

```sh
~ # basename /dev/sdc86
sh: basename: not found
~ # echo $?
127

~ # p=/dev/sdc86; echo ${p##*/}
sdc86
~ # echo $?
0
```

然后**用修复后的逻辑实际挂载一次**：

```sh
~ # findpn() { for b in /sys/class/block/*; do [ -f "$b/partition" ] || continue;
      case "$(cat $b/uevent 2>/dev/null)" in *PARTNAME=$1*) p=${b##*/};
      echo /dev/$p; return 0;; esac; done; return 1; }
~ # P=$(findpn userdata); echo "device=$P"
device=/dev/sdc86
~ # mkdir -p /mnt/t && mount -t ext4 $P /mnt/t && echo MOUNT_OK
MOUNT_OK
~ # [ -x /mnt/t/sbin/init ] && echo INIT_OK
INIT_OK
```

**这个"活体验证"是本次移植中最有价值的一步** —— 它把"我以为修好了"变成"已经证明能用"。

### 顺带一个教训

这类**"环境差异"**（缺 applet、缺文件、缺驱动）比"配置错误"隐蔽得多，
因为：
- 配置文件错误通常会报错
- 而缺 applet 只会让命令返回空字符串，**静默失败**

**排查方法**：在目标环境里实测每个外部命令：

```sh
for c in basename dirname sed awk grep cut tr; do
  printf "%-10s " "$c"
  command -v "$c" >/dev/null 2>&1 && echo "✅" || echo "❌ 缺失"
done
```

---

## 12. `switch_root` 不清理后台进程

### 症状

系统正常启动进桌面，但**手机屏幕永远在刷**：

```
/init: line :sleep: not found
/init: line :sleep: not found
...
```

而 `dmesg` 里**完全干净**：

```
$ dmesg | grep -c 'sleep: not found'
0                                          ← 核心日志里没有！
```

### 排查过程

```bash
$ ps -eo pid,ppid,args | grep '/bin/sh /init'
    181       1 /bin/sh /init          ← PPID 是 1（systemd）
    182       1 /bin/sh /init          ← 被 systemd 收养的孤儿进程
```

**两个 `spawn_shell` 后台循环在 `switch_root` 后存活了下来。**

### 根因

**`exec switch_root` 只替换 PID 1，不清理 PID 1 启动的其他进程。**

initramfs 里用 `&` 起的 shell 循环：

```sh
spawn_shell /dev/ttyGS0 "..." &
spawn_shell /dev/tty1 "..." &        # ← 这个往物理屏幕写
```

- `switch_root` 后它们变成孤儿，被 systemd 收养
- **文件描述符仍指向旧根的 `/dev/tty1`**（因为 `/dev` 是用 `mount --move` 搬过去的，
  设备节点还在，写入不报错）
- 循环里 `sleep 1` 在那个环境下失败 → 无限快速重试 → 每秒刷一条

### 修法

**在 `exec switch_root` 之前显式清理**：

```sh
SPAWNED_PIDS=""
spawn_shell /dev/ttyGS0 "..." &
SPAWNED_PIDS="$SPAWNED_PIDS $!"
spawn_shell /dev/tty1 "..." &
SPAWNED_PIDS="$SPAWNED_PIDS $!"

kill_old_shells() {
	self=$$
	for p in $SPAWNED_PIDS; do
		[ "$p" = "$self" ] && continue
		kill -9 "$p" 2>/dev/null || true
	done
	# 兜底：扫描 /proc 里所有 /init 的 shell
	for d in /proc/[0-9]*; do
		pid=${d##*/}
		[ "$pid" = "1" ] && continue
		[ "$pid" = "$self" ] && continue         # ← 关键：避免自杀
		case "$(cat $d/cmdline 2>/dev/null | tr '\0' ' ')" in
		*"/bin/sh /init"*) kill -9 "$pid" 2>/dev/null || true ;;
		esac
	done
	sleep 1
	return 0
}

# 在 switch_root 前
msg "switching root to $ROOT_PART"
kill_old_shells
exec switch_root /mnt/root /sbin/init
```

**三个细节都不能少**：

| 细节 | 原因 |
|---|---|
| `[ "$pid" = "$self" ] && continue` | 本 shell 的 cmdline **也是** `/bin/sh /init`，不排除就会**自杀** |
| `\|\| true` | 不依赖 `set -e` 语义（`&&` 短路作为循环体最后语句在 `set -e` 下有陷阱） |
| `sleep 1` | 给 SIGKILL 时间生效（busybox 没有 `wait` applet） |

### 验证

```bash
# 启动后
ps -eo pid,ppid,args | grep '/bin/sh /init' | grep -v grep || echo "NO_INIT_LOOPS"
#   期望: NO_INIT_LOOPS
```

---

## 13. 在错误的地方找证据

**这一节是方法论，比任何具体技术点都重要。**
本次移植中我犯了 5 次同类错误，每次都得出"看似合理但完全错误"的结论。

### 教训 1：查了错误的日志源

**我说**："`sleep: not found` 报错已经不存在了。"
**依据**：`journalctl -b | grep sleep` 无输出。

**错在**：那个报错是 initramfs 的 busybox shell **直接写 `/dev/tty1`** 的纯用户态输出，
**根本不会进 journal**。正确的是查 `ps`（找循环进程）+ 对照 `dmesg`（确认内核态干净）。

**教训**：日志清空 ≠ 问题消失。要问"这个输出会流向哪里"。

---

### 教训 2：按错误格式解读二进制

**我说**："原版 ramdisk 用 1 MB 块，我压的用 4 KB 块，所以内核解压失败。"
**依据**：`FLG=0xd0 BD=0x62` vs `FLG=0x30 BD=0x20`。

**错在**：LZ4 legacy 格式**没有** FLG/BD 字段（那是现代 frame 格式的）。
魔数后面 4 字节**就是第一个块的长度**。我按 frame 格式解读，得出完全虚构的结论。

**教训**：解读二进制前，先确认格式规范。别用"看起来像"的字段名硬套。

---

### 教训 3：用了错误的分析工具

**我说**："`/lib/modules/7.2.0` 只有 18 个条目，模块没装上！"
**依据**：`debugfs -R 'ls -l /lib/modules/7.2.0' | wc -l` = 18。

**错在**：`debugfs` 的 `ls` 是**单层**的，18 个条目是"7 个目录 + 11 个文件"。
实际有 1567 个 `.ko` 分布在子树里。正确的是 `rdump` 后 `find | wc -l`。

**教训**：工具的行为要理解清楚（`ls` 单层 vs 递归），别拿计数当结论。

---

### 教训 4：相信了假阳性的检查结果

**我说**："symbol 链接已存在。"
**依据**：`debugfs -R "stat /path/to/symlink" && echo exists` 返回成功。

**错在**：**`debugfs -R "stat <任意路径>"` 对不存在的路径也返回 0**（退出码不可靠）。
必须解析输出里的 `Inode:` 行，或用 `ls` 判断。

```bash
# ❌ 错误
debugfs -R "stat $p" img >/dev/null 2>&1 && echo exists

# ✅ 正确
debugfs -R "stat $p" img 2>/dev/null | grep -q '^ *Inode:' && echo exists
```

**教训**：**必须实际验证检查手段本身是否可靠**（用一个已知不存在的路径做阴性对照）。

---

### 教训 5：把噪声当信号

**我说**："`consys_co_clock_type_mt6895: failed to get regmap` 是根因。"
**依据**：`dmesg` 里这行反复出现。

**错在**：那是 `pr_notice`（非致命），函数仍返回有效的默认时钟方案。
真正的信号是 `Get conf fail`，而它**已经消失了**（证明我的修复生效）。

**教训**：区分日志级别。`pr_notice`/`pr_debug` 通常无害，
`pr_err` 且**导致功能失败**的才是信号。

---

### 总结出的排查纪律

| 纪律 | 具体做法 |
|---|---|
| **先确认证据来源** | 这个输出会流向哪？`dmesg` / `journalctl` / 串口 / 屏幕 / pstore？ |
| **做阴性对照** | 用已知失败/不存在的输入测试你的检查方法 |
| **活体验证** | 别推理"应该好了"，在目标环境**实际执行一次** |
| **区分日志级别** | `notice`/`debug` ≠ `err`；要有"这个错误导致了什么功能失败"的因果链 |
| **警惕历史记录** | pstore 里的记录可能来自旧内核（看 DTB 大小、版本字符串） |
| **一次只改一个变量** | 本次移植中同时改 DTB 大小 + LZ4 参数导致排查困难 |

### 最有效的一个技巧

**当症状"不该存在"时，用最小化实验证伪它。**

例如"插 USB 才能启动"这个诡异现象，最有效的一步是：

```bash
# 手动重新绑定设备（绕过启动时序）
echo 13000000.gpu > /sys/bus/platform/drivers/panthor/unbind
echo 13000000.gpu > /sys/bus/platform/drivers/panthor/bind
```

**一次操作就证明了**："文件没错、路径没错、硬件没错 —— 只是时机不对"。

比读 30 分钟代码有效得多。
