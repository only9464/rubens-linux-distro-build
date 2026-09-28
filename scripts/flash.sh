#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# flash.sh -- 打印（而不是执行）刷机命令
#
#   ./scripts/flash.sh [boot.img] [rootfs.img]
#
# 刻意**不自动刷机**，原因有三：
#
#   1. 刷 userdata 会清空设备数据，不可逆 —— 必须由人确认
#   2. 两个槽位各有 6 次启动重试，耗尽后标记 unbootable。
#      盲目重试会烧掉这些机会。
#   3. 刷机前需要检查槽位状态、镜像尺寸、SHA256 —— 这些应该人来看
#
# 这个脚本做的是：校验镜像 → 检查设备状态 → 打印确切的命令序列。

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

BOOTIMG="${1:-$ROOT/boot-ubuntu.img}"
ROOTFSIMG="${2:-}"

if [ -z "$ROOTFSIMG" ]; then
	# 尝试从 rootfs-builder 的产物里找最新的一份
	ROOTFSIMG=$(ls -t "$ROOT"/rootfs-builder/out/rootfs-rubens-ubuntu-*-sparse.img 2>/dev/null | head -1 || true)
fi

ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }
info() { printf '       %s\n' "$*"; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

echo
echo "================================================================"
echo "  Redmi K50 (rubens) Ubuntu 26.04 刷机指引"
echo "================================================================"

hdr "1. 待刷镜像"
if [ -f "$BOOTIMG" ]; then
	ok "内核: $(basename "$BOOTIMG")  ($(stat -c %s "$BOOTIMG") 字节)"
	info "sha256: $(sha256sum "$BOOTIMG" | cut -d' ' -f1)"

	# 内核尺寸门禁
	python3 - "$BOOTIMG" <<'PY' || exit 1
import gzip, struct, sys
d = open(sys.argv[1], 'rb').read(4096)
ks = struct.unpack_from('<I', d, 8)[0]
total = 4096 + ((ks + 4095) // 4096) * 4096
# 读出 gzip 内核的 arm64 头部
try:
    with open(sys.argv[1], 'rb') as f:
        f.seek(4096)
        k = gzip.decompress(f.read(ks))
    size = struct.unpack_from('<Q', k, 16)[0]
    budget = 0x3640000
    if size >= budget:
        sys.exit(f"  \033[31mFAIL\033[0m image_size 0x{size:x} 超出预算 —— 会复位循环，不要刷")
    print(f"  \033[32mOK\033[0m   image_size = 0x{size:x} ({size/1048576:.3f} MiB), "
          f"余量 {(budget-size)/1024:.1f} KiB")
except Exception as e:
    print(f"  \033[33mWARN\033[0m 无法解析内核尺寸: {e}")
PY
else
	bad "缺失: $BOOTIMG"
fi

if [ -n "$ROOTFSIMG" ] && [ -f "$ROOTFSIMG" ]; then
	ok "系统: $(basename "$ROOTFSIMG")  ($(stat -c %s "$ROOTFSIMG") 字节)"
	info "sha256: $(sha256sum "$ROOTFSIMG" | cut -d' ' -f1)"
	file "$ROOTFSIMG" | sed 's/^/       /'
else
	warn "没有找到 rootfs 镜像 —— 只刷内核的话跳过 userdata 步骤"
fi

hdr "2. 设备状态"
if timeout 10 fastboot devices 2>/dev/null | grep -q fastboot; then
	ok "设备在 fastboot: $(timeout 10 fastboot devices 2>/dev/null | head -1)"

	info "槽位状态:"
	for v in current-slot slot-retry-count:a slot-unbootable:a \
	         slot-retry-count:b slot-unbootable:b; do
		printf '         %-24s ' "$v"
		timeout 10 fastboot getvar "$v" 2>&1 | grep -E "^$v:" | tail -1 | sed 's/.*: *//' || echo "?"
	done

	if [ "$(timeout 10 fastboot getvar current-slot 2>&1 | grep -oE ': *[ab]$' | tr -d ': ')" = "b" ]; then
		BOOTPART="boot_b"
	else
		BOOTPART="boot_a"
	fi
	info "当前槽对应的 boot 分区: $BOOTPART"
else
	bad "设备不在 fastboot"
	info "手动进入: 长按电源约 10 秒关机 → 按住音量下 + 电源"
	BOOTPART="boot_a"
fi

hdr "3. 刷机命令（请自行执行）"
cat <<EOF

  ⚠️  刷 userdata 会清空 Android 及全部用户数据，不可逆。
  ⚠️  开始前确认已备份原厂 boot 分区（见 docs/BUILD.md §6.1）。

  ── 步骤 1：刷内核（不影响 userdata 上的系统）────────────────
    fastboot flash $BOOTPART $(basename "$BOOTIMG")

EOF

if [ -n "$ROOTFSIMG" ] && [ -f "$ROOTFSIMG" ]; then
	cat <<EOF
  ── 步骤 2：刷根文件系统（⚠️ 清空设备数据）──────────────────
    fastboot flash userdata $(basename "$ROOTFSIMG")

EOF
fi

cat <<'EOF'
  ── 步骤 3：重启 ────────────────────────────────────────────
    fastboot reboot

  ── 步骤 4：观察启动 ────────────────────────────────────────
    # initramfs 的日志会双写到 USB 串口
    sudo tio /dev/ttyACM0
    #   或 sudo picocom -b 115200 /dev/ttyACM0

EOF

hdr "4. 首次启动后"
cat <<'EOF'
  ── 扩容（镜像故意只有 1 GiB）──────────────────────────────
    sudo resize2fs $(findmnt -no SOURCE /)

  ── 连接 WiFi（必须指定 ifname wlan0）──────────────────────
    nmcli device wifi list
    nmcli device wifi connect "你的SSID" password "你的密码" ifname wlan0

  ── NO 串口输出时 ───────────────────────────────────────────
    sudo systemctl stop ModemManager     # 它会抢 ttyACM*
    sudo fuser -v /dev/ttyACM0           # 看谁占着
    lsusb | grep -E '0525|18d1'          # 0525:a4a7=Linux gadget, 18d1=fastboot

EOF

hdr "5. 出问题时"
cat <<'EOF'
  ── 回滚到原厂 Android ──────────────────────────────────────
    # 用备份的原厂 boot 分区
    fastboot flash boot_a /path/to/original-boot_a.img
    fastboot flash boot_b /path/to/original-boot_b.img

  ── 读取崩溃日志（pstore）───────────────────────────────────
    # 需要设备能启动到某个系统才能读 oops 分区
    dmesg | grep -i pstore

  ── 槽位被标记 unbootable ───────────────────────────────────
    # 刷入该槽的 boot 分区后 LK 会重新尝试（实测）
    fastboot flash boot_a boot-ubuntu.img
    fastboot --set-active=a
    fastboot reboot-bootloader      # set_active 必须跟这一步才生效

  ⚠️  不要反复盲目试启动 —— 每次失败都在消耗槽位的重试次数。

EOF
