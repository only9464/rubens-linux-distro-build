# 从已验证的 .config 提取「相对上游基线的最小差分」overlay
#
# 用途：kernel.config 是权威的、可直接使用的完整配置（328 KB），
#       但这个脚本生成人类可读的最小差分（约 40 项），便于 code review 和
#       理解每一项为什么存在。
#
#   用法: ./extract-overlay.sh <kernel-src> <verified.config> <output.config>
#
# 原理：把 defconfig + rubens.config 合并成基线，再与已验证配置求差。

set -euo pipefail

KERNEL="${1:?usage: $0 <kernel-src> <verified.config> <output>}"
VERIFIED="${2:?usage: $0 <kernel-src> <verified.config> <output>}"
OUTPUT="${3:?usage: $0 <kernel-src> <verified.config> <output>}"

# 输出路径必须在 cd 之前解析成绝对路径，否则相对路径会相对源码树解析
case "$OUTPUT" in
	/*) : ;;
	*) OUTPUT="$PWD/$OUTPUT" ;;
esac
case "$VERIFIED" in
	/*) : ;;
	*) VERIFIED="$PWD/$VERIFIED" ;;
esac

[ -d "$KERNEL" ] || { echo "not a directory: $KERNEL" >&2; exit 1; }
[ -f "$VERIFIED" ] || { echo "not a file: $VERIFIED" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cd "$KERNEL"

# merge_config.sh 需要一个干净的 .config 才能正确落盘，先清掉
rm -f "$WORK/.config"

echo "==> 生成基线: defconfig + rubens.config"
make ARCH=arm64 LLVM=1 O="$WORK/build" defconfig >/dev/null 2>&1 || true
./scripts/kconfig/merge_config.sh -m -O "$WORK/build" \
	arch/arm64/configs/defconfig \
	arch/arm64/configs/rubens.config >/dev/null 2>&1
make ARCH=arm64 LLVM=1 O="$WORK/build" olddefconfig >/dev/null 2>&1

BASE="$WORK/build/.config"
[ -f "$BASE" ] || { echo "failed to produce a baseline .config" >&2; exit 1; }
echo "    基线: $(grep -c '^CONFIG_' "$BASE") 项"

echo "==> 求差"
{
	cat <<'EOF'
# ============================================================================
# 相对上游基线的配置差分
#
# 基线 = arch/arm64/configs/defconfig + arch/arm64/configs/rubens.config
# 本文件 = 已验证可启动的配置与基线的差值
#
# 用法:
#   ./scripts/kconfig/merge_config.sh -m -O out out/.config <本文件>
#   make ARCH=arm64 LLVM=1 O=out olddefconfig
#
# 每一项的原因说明见 docs/BUILD.md §3.3 和 docs/PITFALLS.md
# ============================================================================

EOF
	# 新增/变更项
	diff <(grep '^CONFIG_' "$BASE" | sort) <(grep '^CONFIG_' "$VERIFIED" | sort) \
		| grep '^>' | sed 's/^> //' || true
	# 被关闭项
	diff <(grep '^CONFIG_' "$BASE" | sort) <(grep '^CONFIG_' "$VERIFIED" | sort) \
		| grep '^<' | sed 's/^< /# /; s/=$/ is not set/' || true
} > "$OUTPUT"

echo "    输出: $OUTPUT ($(grep -cE '^CONFIG_|^# CONFIG_' "$OUTPUT") 项)"
echo
echo "注意：kernel.config 才是权威配置。本差分仅供人阅读，"
echo "      重新生成配置时请优先直接使用 kernel.config。"
