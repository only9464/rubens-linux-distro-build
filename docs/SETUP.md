# 新建 GitHub 仓库操作指引

把 `rubens-ubuntu-build/` 这个目录变成一个可以跑构建的 GitHub 仓库。

---

## 1. 这个仓库里放什么、不放什么

**只放从 GitHub 下载不到的文件**（这是本仓库存在的唯一理由）：

| 内容 | 大小 | 为什么不放 GitHub 就下不到 |
|---|---|---|
| `firmware/` | 3.2 MB | **厂商固件**（WiFi / 蓝牙 / Mali GPU / 触摸屏）。版权原因，任何公开仓库都不会分发 |
| `ramdisk-proven.lz4` | 729 KB | 在**真机上验证过能启动**的 initramfs。它包含针对本设备修正过的 `/init` |
| `configs/kernel.config` | 321 KB | 实测能通过 LK 体积上限、且 WiFi/蓝牙/GPU/传感器全部工作的内核配置 |
| `patches/` | 29 KB | 移植补丁（上游基线之上必须的 5 个文件改动） |
| `scripts/` | 34 KB | 构建脚本 |
| `docs/` | 94 KB | 文档（含 `SOURCES.md` 逐文件来源台账） |
| `.github/workflows/build.yml` | 47 KB | 构建流程（内嵌设备 profile、Ubuntu 后端与 `build.sh` 补丁） |

**不放**（workflow 运行时从 GitHub 克隆）：

- 内核源码 —— `git clone` 指定仓库/分支/commit
- rootfs 构建器 —— `git clone MT6895-Mainline/rootfs`
- 编译产物 —— 每次构建生成，用 Artifact 下载

**仓库总大小约 4.5 MB。** 没有 LFS 需求。

逐个文件的出处与生成过程见 **[SOURCES.md](SOURCES.md)**。

---

## 2. 创建仓库

### 2.1 方式 A：网页创建后推送

```bash
# 在 GitHub 网页上新建空仓库（不要勾选 README / .gitignore / License）
# 假设仓库地址是 https://github.com/<你的用户名>/rubens-ubuntu-2604.git

cd /path/to/rubens-ubuntu-build
git init
git add -A
git -c user.name="你的名字" -c user.email="你的邮箱" \
    commit -m "Redmi K50 Ubuntu 26.04 构建：固件、配置、补丁与 workflow"
git branch -M main
git remote add origin https://github.com/<你的用户名>/rubens-ubuntu-2604.git
git push -u origin main
```

### 2.2 方式 B：用 gh CLI

```bash
cd /path/to/rubens-ubuntu-build
gh repo create rubens-ubuntu-2604 --private --source=. --push
```

> **建议用 private**：虽然固件是从你自己设备提取的，但公开分发厂商 blobs
> 在法律上有争议。私有仓库没有这个问题。

### 2.3 推送前自检

```bash
# 确认固件都在
ls -la firmware/arm/mali/arch10.8/mali_csffw.bin
ls -la firmware/conninfra.cfg
ls -la firmware/WIFI_RAM_CODE_soc7_0_1b_t_1.bin

# 确认 ramdisk 在
sha256sum ramdisk-proven.lz4
#   期望: b143356b498ce8f634a8bc70b2c23ea5d507f12f9a338af006b4132c301914ed

# 确认不会被 .gitignore 误排
git status --short | grep -c firmware    # 应该是 16（16 个固件文件）
git check-ignore -v firmware/conninfra.cfg && echo "❌ 被忽略了！" || echo "✅ 会被提交"
```

---

## 3. 手动触发构建

推到 GitHub 后：

1. 打开仓库 → **Actions** 标签
2. 左侧选 **构建 rubens Ubuntu 26.04**
3. 右侧 **Run workflow** 按钮
4. 填写输入（见下），点绿色的 **Run workflow**

### 3.1 四个输入框

| 输入 | 留空时的行为 |
|---|---|
| **内核仓库地址** | 用默认 `https://github.com/MT6895-Mainline/linux.git` |
| **分支名** | 若填了地址则**自动探测该仓库的主分支**；若地址也留空则用 `port/rubens-clean` |
| **commit / tag** | 用该分支的**最新提交**。（三个都留空时才用被验证过的 `80d38270aa`） |
| **把 GNOME 桌面打进镜像** | 不打。镜像约 130 MB |

**组合行为对照**：

| 地址 | 分支 | commit | 实际使用 |
|---|---|---|---|
| 空 | 空 | 空 | 默认仓库 + `port/rubens-clean` + `80d38270aa`（**已验证组合**） |
| 空 | 空 | `abc1234` | 默认仓库 + `port/rubens-clean` + `abc1234` |
| 空 | `mybranch` | 空 | 默认仓库 + `mybranch` 最新 |
| `https://github.com/foo/bar.git` | 空 | 空 | `foo/bar` 的**主分支**最新 |
| `https://github.com/foo/bar.git` | `dev` | 空 | `foo/bar` 的 `dev` 最新 |
| `https://github.com/foo/bar.git` | `dev` | `deadbeef` | 完全指定 |

> 换内核版本时补丁可能对不上 —— workflow 里有一步"补丁冲突排查"会把冲突细节打出来。
> 相关说明见 `docs/BUILD.md` §3.1。

### 3.2 构建耗时

| 阶段 | 16 核 | 4 核（GitHub 免费 runner） |
|---|---|---|
| 工具链安装 | 1 分 | 1 分 |
| 内核编译 | 15 分 | **约 60 分** |
| rootfs 构建 | 8 分 | 约 20 分 |
| boot.img 打包 | 1 分 | 1 分 |
| **合计** | **约 25 分** | **约 80 分** |

workflow 设了 `timeout-minutes: 180`，够用。

> ⚠️ GitHub 免费 runner 是 4 核，内核编译会比较慢。如果嫌慢，可以考虑
> self-hosted runner，或只在需要时触发。

### 3.3 拿到产物

构建成功后，在 Actions 页面那次运行的底部 **Artifacts** 区域下载：

```
rubens-ubuntu-2604-<run号>.zip
├── Image                                内核
├── mt6895-xiaomi-rubens.dtb             设备树
├── .config                              实际使用的配置
├── boot-ubuntu.img                      刷入 boot_a 的启动镜像
├── rootfs-rubens-ubuntu-*-sparse.img    刷入 userdata 的系统镜像
├── KERNEL-INFO-rubens-ubuntu.txt
└── SHA256SUMS                           校验和
```

---

## 4. 刷机

⚠️ **刷入会清空 Android 及全部用户数据，不可逆。**

```bash
# 1. 手机进 fastboot（长按电源 10 秒 → 音量下 + 电源）
fastboot devices

# 2. 刷入（按顺序）
fastboot flash boot_a boot-ubuntu.img
fastboot flash userdata rootfs-rubens-ubuntu-*-sparse.img
fastboot reboot
```

**首次启动后**（设备上执行，或通过 USB 串口 `sudo picocom -b 115200 /dev/ttyACM0`）：

```bash
# 扩容（镜像故意只有 1 GiB）
sudo resize2fs $(findmnt -no SOURCE /)

# 连 WiFi（必须指定 ifname wlan0，否则 NetworkManager 会选错虚拟接口）
nmcli device wifi connect "你的SSID" password "你的密码" ifname wlan0
```

完整步骤见 `docs/BUILD.md` §6–7。**刷机前请先读 `docs/PITFALLS.md`。**

---

## 5. 关于固件的一些说明

### 5.1 固件是从哪来的

教程作者从**自己的** Redmi K50 上提取的。提取方法通常是：

- 从设备 root 权限下读取相关分区
- 或从官方 ROM 包里解包

**你应该用你自己设备的固件**，而不是直接信任这里的副本 —— 虽然同一机型的固件
一般相同，但校准数据（WiFi MAC、BT 地址）是**每台设备独有**的。

### 5.2 哪些固件是必须的

**构建必需**（缺了 workflow 会失败）：

| 文件 | 大小 | 作用 |
|---|---|---|
| `arm/mali/arch10.8/mali_csffw.bin` | 276 KB | **GPU 固件** —— 缺了没有硬件加速，GNOME 会卡 |
| `conninfra.cfg` | **17 字节** | **conninfra 共时钟配置** —— 缺了 WiFi 首次上电失败、日志刷屏 |
| `WIFI_RAM_CODE_soc7_0_1b_t_1.bin` | 1.1 MB | WiFi 主固件 |
| `soc7_0_ram_wmmcu_1b_t_1_hdr.bin` | 468 KB | WiFi MCU 固件 |
| `wifi.cfg` | 1.1 KB | WiFi 配置 |
| `BT_FW.cfg` | 443 B | 蓝牙固件配置 |
| `soc7_0_ram_bt_1b_t_1_hdr.bin` | 586 KB | 蓝牙固件 |
| `soc7_0_ram_mcu_1b_t_1_hdr.bin` | 144 KB | 连接子系统 MCU |
| `st_fts_L11a.ftb` | 127 KB | 触摸屏固件 |
| `stm_fts_production_limits.csv` | 30 KB | 触摸屏校准参数 |

**可选**（不影响启动和主要功能）：

`aw8697_haptic.bin`、`aw8697_rtp_1.bin`（振动马达）、`tfa98xx.cnt`（功放）、
`mali_csffw.bin`、`mali_csffw_reload.bin`（旧架构 Mali 固件，本项目未用）

### 5.3 不要提交到公开仓库

如果一定要公开，建议：

1. 把仓库设为 private（最简单）
2. 或只提交 `scripts/`、`configs/`、`patches/`、`docs/`、`workflow`，
   固件通过其它途径提供，并在文档里说明如何自行提取

---

## 6. 常见问题

### 为什么构建跑在容器里

GitHub 托管 runner 目前只有 **ubuntu-24.04**，它自带的工具链与本移植的
**验证环境不符**，而且是硬阻塞而不是"可能有问题"：

| 工具 | 24.04 runner | 需要 | 后果 |
|---|---|---|---|
| clang | **18.1.3** | 21 | 编不过内核 |
| **lz4** | **1.9.4** | 1.10.0 | 在 legacy 模式下产出的流**内核解压不了** → boot.img 直接启动失败 |
| mmdebstrap | 1.4.3 | 1.5.7 | 构建 26.04 rootfs 可靠性未知 |

所以 workflow 用 `container:` 跑在 **ubuntu:26.04** 里：

```yaml
jobs:
  build:
    runs-on: ubuntu-24.04        # 只是宿主，不参与构建
    container:
      image: ubuntu:26.04        # 与本地验证环境一致的工具链
      options: --user root
```

容器内实测得到的版本（与验证环境逐项一致）：

```
Ubuntu 26.04.1 LTS
clang 21.1.8 / LLD 21.1.8
mmdebstrap 1.5.7
lz4 1.10.0
make 4.4.1
```

**不要改回让 runner 直接跑** —— 那会引入至少两个必修的工具链问题。

### workflow 报 "mkbootimg 不可用"

`mkbootimg` 在 Ubuntu 26.04 里是 **universe 的正式包**
（`source: android-platform-tools`），workflow 已用 apt 安装。

**不要用 pip 装它** —— Ubuntu 26.04 是 PEP 668 的 externally-managed 环境，
`pip install` 会直接失败：

```
error: externally-managed-environment
```

### workflow 在 rootfs 阶段报 mount 相关错误

`mmdebstrap` 需要创建 chroot 和 mount namespace，而 Docker 的 seccomp 策略
在少数环境下会拦截。若看到 `Operation not permitted`（且确认不是别的错误），
给容器加特权：

```yaml
      options: --user root --privileged
```

**优先不加** —— 先用默认配置试，只在确实被拦截时才加。

### workflow 报 "image_size 超出预算"

说明新加的内建代码把内核撑大了。**不要刷入**（会复位循环）。

**排查**：看 `scripts/ci-summary.sh` 输出的余量，然后在 `configs/kernel.config` 里
把非必需的驱动从 `=y` 改为 `=m`（模块不占 Image 体积）。

### workflow 报 "rootfs 缺少 /usr/sbin/wpa_supplicant"

`rootfs/devices/rubens-ubuntu.conf` 的 `PACKAGES_EXTRA` 里漏了 `wpasupplicant`。
workflow 的"调整设备配置"步骤会自动补上，如果仍失败说明上游改了文件结构。

### 构建成功但设备刷完不启动

按顺序检查：

1. **boot.img 的 image_size**（见 `SHA256SUMS` 同目录的摘要）
2. **串口有没有输出** —— `sudo tio /dev/ttyACM0`，initramfs 的日志双写到串口
3. **槽位状态** —— `fastboot getvar slot-unbootable:a`
4. **读 pstore** —— 崩溃日志在 `oops` 分区

详见 `docs/PITFALLS.md` 第 13 节（排查纪律）。

---

## 7. 后续维护建议

| 场景 | 做法 |
|---|---|
| **上游内核更新** | 手动触发 workflow，填 `port/rubens-clean` 不填 commit，看补丁是否还对得上 |
| **想长期跟上游** | 定期跑一次，标记哪些 commit 会导致补丁冲突 |
| **改了配置** | 本地编译验证 `image_size` 在预算内，再更新 `configs/kernel.config` |
| **换了设备固件** | 直接替换 `firmware/` 下的文件后提交 |

**建议给仓库加一个 `docs/CHANGELOG.md`**，记录每次内核基线变更和对应结论 ——
这个移植的历史里，"哪个 commit 引入了什么坑"是最有价值的信息。
