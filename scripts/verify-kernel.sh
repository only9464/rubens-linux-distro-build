#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# verify-kernel.sh -- 内核编译后的门禁检查
#
#   ./scripts/verify-kernel.sh <kernel-out-dir>
#
# 任何一项失败都应该阻止后续的刷机流程。特别是 image_size：
# 超过 LK 预算的内核必定复位循环，刷进去只会浪费一次宝贵的槽位重试。

set -u

KB="${1:-kernel/out}"
IMAGE="$KB/arch/arm64/boot/Image"
DTB="$KB/arch/arm64/boot/dts/mediatek/mt6895-xiaomi-rubens.dtb"
CFG="$KB/.config"

# LK 的硬约束。0x3640000 是作者实测能启动的最大值；
# 0x3820000 是已知会复位循环的值。取前者作为门禁线。
BUDGET=$((0x3640000))
OVER=$((0x3820000))
EXPECTED_RELEASE="7.2.0"

ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }
info() { printf '       %s\n' "$*"; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

fail=0

hdr "1. 产物存在性"
for f in "$IMAGE" "$DTB" "$CFG"; do
	if [ -f "$f" ]; then
		ok "$(basename "$f")  ($(stat -c %s "$f") 字节)"
	else
		bad "缺失: $f"; fail=$((fail+1))
	fi
done
[ "$fail" -gt 0 ] && { echo; bad "编译不完整，中止检查"; exit 1; }

hdr "2. LK 体积预算（最关键的门禁）"
python3 - "$IMAGE" "$BUDGET" "$OVER" <<'PY' || fail=$((fail+1))
import struct, sys
image, budget, over = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
d = open(image, 'rb').read(64)
if d[56:60] != b'ARM\x64':
    sys.exit(f"  \033[31mFAIL\033[0m 不是 arm64 Image (magic={d[56:60]!r})")
size = struct.unpack_from('<Q', d, 16)[0]
head = budget - size
print(f"       image_size = 0x{size:x}  ({size/1048576:.3f} MiB)")
print(f"       预算       = 0x{budget:x}  ({budget/1048576:.3f} MiB)")
print(f"       余量       = {head} 字节 ({head/1024:.1f} KiB)")
if size < budget:
    if head < 128 * 1024:
        print(f"  \033[33mWARN\033[0m 在预算内但余量不足 128 KiB —— "
              f"任何新增内建代码都可能导致复位循环")
        print(f"       新增驱动请用 =m（模块），不要用 =y")
    else:
        print(f"  \033[32mOK\033[0m   在预算内")
elif size < over:
    sys.exit(f"  \033[31mFAIL\033[0m 超出已验证上限 {size-budget} 字节，"
             f"但低于已知失效点 0x{over:x} —— 启动是赌博，不要刷")
else:
    sys.exit(f"  \033[31mFAIL\033[0m 达到已知失效点 0x{over:x} —— 必定复位循环")
PY

hdr "3. 内核版本字符串"
REL=$(cat "$KB/include/config/kernel.release" 2>/dev/null || echo "?")
if [ "$REL" = "$EXPECTED_RELEASE" ]; then
	ok "kernel.release = $REL"
else
	bad "kernel.release = '$REL'，期望 '$EXPECTED_RELEASE'"
	info "带 '+' 后缀说明工作区脏且未传 LOCALVERSION= —— 1608 个模块会全部失配"
	info "修法: 提交本地改动，并且编译时传 LOCALVERSION="
	fail=$((fail+1))
fi

hdr "4. 关键功能配置"
check() { # symbol expected label
	v=$(grep -E "^$1=" "$CFG" 2>/dev/null | head -1 | cut -d= -f2-)
	if [ "$v" = "$2" ]; then ok "$3  ($1=$v)"
	else bad "$3 -- $1 是 '${v:-未设置}'，期望 '$2'"; fail=$((fail+1)); fi
}
check CONFIG_XIAOMI_RUBENS              y "Image 内嵌 rubens DTB"
check CONFIG_SCSI_UFS_MEDIATEK          y "UFS 存储（挂载 rootfs 必需）"
check CONFIG_EXT4_FS                    y "根文件系统"
check CONFIG_PSTORE_BLK                 y "崩溃日志通道（启动失败时唯一手段）"
check CONFIG_MEDIATEK_WATCHDOG          y "看门狗"
check CONFIG_MTK_COMBO                  y "WiFi 栈"
check CONFIG_MTK_BTIF                   y "蓝牙 BTIF"
check CONFIG_MTK_TINYSYS_SCP_SUPPORT    y "SCP 协处理器"
check CONFIG_MTK_SENSORHUB              y "传感器 hub"
check CONFIG_DRM_PANTHOR                y "Mali GPU 驱动"
check CONFIG_NF_TABLES                  m "nftables（Docker 需要）"

hdr "5. 体积限制项必须关闭"
# 注意：某些符号在依赖被关掉后会**从 .config 里彻底消失**，而不是留下
# "# CONFIG_X is not set" 这一行。这也算"已关闭"，不能误报 WARN。
# 例：CONFIG_RPMSG_MTK_SCP 依赖 MTK_SCP，后者关闭后前者就不存在了。
for s in CONFIG_KALLSYMS_ALL CONFIG_PHY_MTK_MIPI_DSI CONFIG_MTK_CMDQ \
         CONFIG_MTK_SCP CONFIG_RPMSG_MTK_SCP CONFIG_LOCALVERSION_AUTO \
         CONFIG_SECURITY_APPARMOR CONFIG_SECURITY_NETWORK CONFIG_SECURITY_PATH; do
	if grep -q "^# $s is not set" "$CFG"; then
		ok "$s 已关闭"
	elif ! grep -qE "^$s=" "$CFG"; then
		ok "$s 不存在（依赖已关闭，等效关闭）"
	else
		warn "$s 仍为 '$(grep -E "^$s=" "$CFG" | head -1 | cut -d= -f2)' —— 确认这是有意的"
	fi
done

hdr "6. Image 内嵌 DTB 一致性"
python3 - "$IMAGE" "$DTB" <<'PY' || fail=$((fail+1))
import hashlib, struct, sys
image, dtb = sys.argv[1], sys.argv[2]
d = open(image, 'rb').read()
i = d.find(b'\xd0\x0d\xfe\xed')
if i < 0:
    sys.exit("  \033[31mFAIL\033[0m Image 里找不到内嵌 DTB —— "
             "setup.c 会解引用不存在的符号区，内核无法启动")
total, = struct.unpack_from('>I', d, i + 4)
emb = d[i:i + total]
want = open(dtb, 'rb').read()
print(f"       内嵌: {total} 字节 @ 0x{i:x}  sha256 {hashlib.sha256(emb).hexdigest()[:16]}")
print(f"       源码: {len(want)} 字节          sha256 {hashlib.sha256(want).hexdigest()[:16]}")
if emb == want:
    print("  \033[32mOK\033[0m   字节一致")
else:
    sys.exit("  \033[31mFAIL\033[0m 内嵌 DTB 与源码 DTB 不一致")
PY

hdr "7. 模块"
N=$(find "$KB" -name '*.ko' 2>/dev/null | wc -l)
if [ "$N" -gt 1000 ]; then
	ok "$N 个 .ko"
else
	bad "只有 $N 个 .ko —— 模块可能没编完"
	fail=$((fail+1))
fi

hdr "总结"
printf '  %d 项失败\n' "$fail"
if [ "$fail" -eq 0 ]; then
	cat <<'EOF'

  内核检查通过，可以继续构建 rootfs。

  下一步:
    rm -rf rootfs-builder/out/kernel-cache
    cp -a kernel/out rootfs-builder/out/kernel-cache
    cd rootfs-builder && sudo ./build.sh --device rubens-ubuntu ...
EOF
fi
exit "$fail"
