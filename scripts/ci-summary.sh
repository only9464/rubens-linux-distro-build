#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# ci-summary.sh -- 生成 GitHub Actions 的 Job Summary
#
#   ./scripts/ci-summary.sh <kernel-out-dir>
#
# 单独成文件而不是内联在 workflow 里，是因为 workflow 的 YAML 块标量
# （run: |）不允许其内部出现**缩进比它更浅**的行 —— 而 Python 的多行
# 字符串在 YAML 里极易被错误地 dedent，导致整个 workflow 静默解析失败。
# 把逻辑放进脚本，workflow 里只留一行调用。

set -u

KB="${1:-kernel/out}"
IMAGE="$KB/arch/arm64/boot/Image"
BUDGET=$((0x3640000))
OVER=$((0x3820000))

out() { printf '%s\n' "$*"; }

out "## 构建结果"
out ""

if [ ! -f "$IMAGE" ]; then
	out "❌ 内核未生成 —— 构建失败，请查看上方步骤日志。"
	exit 0
fi

SIZE=$(python3 -c "
import struct
d = open('$IMAGE', 'rb').read(64)
print(struct.unpack_from('<Q', d, 16)[0])" 2>/dev/null || echo 0)

KC=$(find "$KB" -name '*.ko' 2>/dev/null | wc -l)
DTB="$KB/arch/arm64/boot/dts/mediatek/mt6895-xiaomi-rubens.dtb"
DTBSZ=$([ -f "$DTB" ] && stat -c %s "$DTB" || echo 0)
REL=$(cat "$KB/include/config/kernel.release" 2>/dev/null || echo "?")

out "| 项目 | 值 |"
out "|---|---|"
out "| 内核版本 | \`$REL\` |"
out "| image_size | \`0x$(printf %x "$SIZE")\` ($(awk "BEGIN{printf \"%.3f\", $SIZE/1048576}") MiB) |"
out "| LK 预算 | \`0x$(printf %x "$BUDGET")\` ($(awk "BEGIN{printf \"%.3f\", $BUDGET/1048576}") MiB) |"
out "| 余量 | $(awk "BEGIN{printf \"%.1f\", ($BUDGET-$SIZE)/1024}") KiB |"
out "| DTB | $DTBSZ 字节 |"
out "| 模块数 | $KC |"
out ""

# 体积判定 —— 这是最关键的结论
if [ "$SIZE" -lt "$BUDGET" ]; then
	HEAD=$((BUDGET - SIZE))
	if [ "$HEAD" -lt 131072 ]; then
		out "### ⚠️ 体积：通过但余量不足"
		out ""
		out "距 LK 预算仅剩 $((HEAD / 1024)) KiB。"
		out "任何新增的**内建**代码（\`=y\`）都可能把设备推入复位循环。"
		out "新增驱动请用 \`=m\`（模块）。"
	else
		out "### ✅ 体积：通过（余量 $((HEAD / 1024)) KiB）"
	fi
elif [ "$SIZE" -lt "$OVER" ]; then
	out "### ❌ 体积：超出已验证上限"
	out ""
	out "image_size 超过 \`0x3640000\`（作者实测能启动的最大值）$(( (SIZE - BUDGET) / 1024 )) KiB。"
	out "虽然低于已知失效点 \`0x3820000\`，但**不要刷入** —— 启动是赌博。"
else
	out "### ❌ 体积：达到已知失效点"
	out ""
	out "image_size ≥ \`0x3820000\`，**必定复位循环**。必须裁剪内置代码。"
fi

out ""
out "### 刷机命令"
out ""
out '```bash'
out "# 内核（只刷这个不影响 userdata 上的系统）"
out "fastboot flash boot_a boot-ubuntu.img"
out ""
out "# 根文件系统（⚠️ 会清空设备数据）"
out "fastboot flash userdata rootfs-rubens-ubuntu-*-sparse.img"
out ""
out "fastboot reboot"
out '```'
out ""
out "首次启动后记得："
out ""
out '```bash'
out "# 扩容（镜像故意只有 1 GiB）"
out "sudo resize2fs \$(findmnt -no SOURCE /)"
out ""
out "# 连 WiFi（必须指定 ifname wlan0）"
out 'nmcli device wifi connect "SSID" password "PW" ifname wlan0'
out '```'
out ""
out "详细步骤见 [\`docs/BUILD.md\`](../blob/main/docs/BUILD.md) §6–7。"
out "踩坑清单见 [\`docs/PITFALLS.md\`](../blob/main/docs/PITFALLS.md)。"
