#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# make-bootimg.sh -- 从内核 Image + 已验证的 ramdisk 打包出可刷入的 boot.img
#
#   sudo ./scripts/make-bootimg.sh [--kernel <Image>] [--ramdisk <ramdisk.lz4>] [--out <boot.img>]
#
# 这个脚本**不编译内核**。它做四件事，每一件都对应一个踩过的坑：
#
#   1. 解包已验证的 ramdisk（含修正过的 /init）
#   2. 注入内建驱动在 rootfs 挂载前就需要的固件  ← PITFALLS §6 / §8
#   3. 重新应用 /init 的两个必需补丁            ← PITFALLS §11 / §12
#   4. 用 LK 能识别的参数打包并校验              ← PITFALLS §10
#
# 关于「已验证的 ramdisk」：项目的 ramdisk 基线必须是**在一个真实设备上成功启动过**
# 的那一份字节。不要尝试用 lz4 重新压缩一个 cpio 来复现它 —— 见 PITFALLS §10 的
# 格式陷阱，以及 docs/BUILD.md §5 的说明。

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

KERNEL="$ROOT/kernel/out/arch/arm64/boot/Image"
RAMDISK="$ROOT/ramdisk-proven.lz4"
FWDIR="$ROOT/firmware"
OUT="$ROOT/boot-ubuntu.img"

# ramdisk 的 LZ4 legacy 魔数
LZ4_MAGIC="02214c18"

while [ $# -gt 0 ]; do
	case "$1" in
	--kernel)  KERNEL="${2:?}";  shift 2 ;;
	--ramdisk) RAMDISK="${2:?}"; shift 2 ;;
	--firmware) FWDIR="${2:?}";  shift 2 ;;
	--out)     OUT="${2:?}";     shift 2 ;;
	-h|--help) sed -n '2,25p' "$0"; exit 0 ;;
	*) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
	esac
done

# 优先用系统 lz4 1.10.0；conda 的 1.9.4 在 legacy 模式下产出内核不认的流
LZ4=/usr/bin/lz4
[ -x "$LZ4" ] || LZ4=$(command -v lz4)

WORK=$(mktemp -d /tmp/mkboot-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# 取文件开头 4 字节的十六进制。xxd 属于 vim-common，精简容器里不一定有
# （CI 的 ubuntu:26.04 就没有，run 12 因此报 "xxd: command not found"）。
# od 属于 coreutils，任何环境都有，输出等价：
#   xxd -p -l4 f  ==  od -An -tx1 -N4 f | tr -d ' \n'
hex4() {
	if command -v xxd >/dev/null 2>&1; then
		xxd -p -l4 "$1"
	else
		od -An -tx1 -N4 "$1" | tr -d ' \n'
	fi
}

ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }
info() { printf '       %s\n' "$*"; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

# 依赖自检：这些工具缺任何一个都会在后面的步骤里以难懂的方式失败
hdr "0. 依赖自检"
_dep_fail=0
for t in "$LZ4" gzip cpio mkbootimg python3 stat mktemp; do
	if command -v "$t" >/dev/null 2>&1; then
		info "$t -> $(command -v "$t")"
	else
		bad "缺少依赖: $t"
		_dep_fail=1
	fi
done
[ "$_dep_fail" = 0 ] || { echo; bad "请先安装缺失的工具"; exit 1; }

hdr "1. 输入检查"
for f in "$KERNEL" "$RAMDISK"; do
	if [ -f "$f" ]; then ok "$(basename "$f")  ($(stat -c %s "$f") 字节)"
	else bad "缺失: $f"; exit 1; fi
done

# 内核尺寸预检
python3 - "$KERNEL" <<'PY' || exit 1
import struct, sys
d = open(sys.argv[1], 'rb').read(64)
if d[56:60] != b'ARM\x64':
    sys.exit(f"  \033[31mFAIL\033[0m 不是 arm64 Image")
size = struct.unpack_from('<Q', d, 16)[0]
budget = 0x3640000
if size >= budget:
    sys.exit(f"  \033[31mFAIL\033[0m image_size 0x{size:x} 超出预算 0x{budget:x}")
print(f"  \033[32mOK\033[0m   image_size = 0x{size:x} ({size/1048576:.3f} MiB), "
      f"余量 {(budget-size)/1024:.1f} KiB")
PY

hdr "2. 解包已验证的 ramdisk"
$LZ4 -l -d -f "$RAMDISK" "$WORK/rd.cpio" >/dev/null 2>&1 || {
	bad "lz4 解包失败"; exit 1; }
mkdir -p "$WORK/root"
(cd "$WORK/root" && cpio -idm < "$WORK/rd.cpio") >/dev/null 2>&1
[ -f "$WORK/root/init" ] || { bad "ramdisk 里没有 /init"; exit 1; }
ok "解出 $(find "$WORK/root" | wc -l) 个条目"

hdr "3. 注入内建驱动需要的固件"
# 这两个文件必须在 initramfs 里，因为内建驱动在 ~1.4s probe，
# 而 rootfs 在 ~3.3s 才挂载。缺少它们的后果见 PITFALLS §6 和 §8。
for spec in \
	"arm/mali/arch10.8/mali_csffw.bin:Mali GPU 固件（缺则无硬件加速）" \
	"conninfra.cfg:conninfra 共时钟配置（缺则 WiFi 上电失败）"
do
	rel="${spec%%:*}"
	label="${spec#*:}"
	src="$FWDIR/$rel"
	if [ -f "$src" ]; then
		install -d "$WORK/root/lib/firmware/$(dirname "$rel")"
		install -m 0644 "$src" "$WORK/root/lib/firmware/$rel"
		ok "$rel  ($(stat -c %s "$src") 字节) -- $label"
	else
		bad "缺少固件源: $src"
		info "  $label"
		exit 1
	fi
done

hdr "4. 修补 /init"
INIT="$WORK/root/init"
before=$(stat -c %s "$INIT")

# --- 补丁 A: basename -> 参数展开（PITFALLS §11）
# busybox 没有 basename applet，命令替换返回空字符串，
# 于是 find_part_by_name 返回 "/dev/" 而非 "/dev/sdc86"，挂载必然失败。
n_base=$(grep -c 'basename' "$INIT" 2>/dev/null || true)
n_base=${n_base:-0}
if [ "$n_base" -gt 0 ]; then
	sed -i 's|echo "/dev/$(basename "$b")"|echo "/dev/${b##*/}"|g' "$INIT"
	sed -i "s|printf ' %s' \"\$(basename \"\$b\")\"|printf ' %s' \"\${b##*/}\"|g" "$INIT"
	left=$(grep -c 'basename' "$INIT" 2>/dev/null || true)
	left=${left:-0}
	if [ "$left" = "0" ]; then
		ok "替换了 $n_base 处 basename -> \${b##*/}"
	else
		bad "仍有 $left 处 basename 未替换"
		grep -n 'basename' "$INIT" | sed 's/^/       /'
		exit 1
	fi
else
	ok "basename 已修复（幂等）"
fi

# --- 补丁 B: switch_root 前杀掉后台 shell（PITFALLS §12）
# exec switch_root 只替换 PID 1，不清理其子进程。这些 shell 的 fd 仍指向
# 旧根的 /dev/tty1，会永久刷屏 "/init: line :sleep: not found"。
if ! grep -q 'kill_old_shells' "$INIT"; then
	python3 - "$INIT" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()

old_calls = ('spawn_shell /dev/ttyGS0 "rubens Linux shell on USB CDC ACM (ttyGS0)" &\n'
             'spawn_shell /dev/tty1 "rubens Linux shell on the panel VT (tty1)" &')
assert old_calls in s, "找不到 spawn_shell 调用块"

new_calls = (
    'SPAWNED_PIDS=""\n'
    'spawn_shell /dev/ttyGS0 "rubens Linux shell on USB CDC ACM (ttyGS0)" &\n'
    'SPAWNED_PIDS="$SPAWNED_PIDS $!"\n'
    'spawn_shell /dev/tty1 "rubens Linux shell on the panel VT (tty1)" &\n'
    'SPAWNED_PIDS="$SPAWNED_PIDS $!"\n'
    '\n'
    'kill_old_shells() {\n'
    '\tself=$$\n'
    '\tfor p in $SPAWNED_PIDS; do\n'
    '\t\t[ "$p" = "$self" ] && continue\n'
    '\t\tkill -9 "$p" 2>/dev/null || true\n'
    '\tdone\n'
    '\tfor d in /proc/[0-9]*; do\n'
    '\t\tpid=${d##*/}\n'
    '\t\t[ "$pid" = "1" ] && continue\n'
    '\t\t[ "$pid" = "$self" ] && continue\n'
    '\t\tcase "$(cat $d/cmdline 2>/dev/null | tr \'\\0\' \' \')" in\n'
    '\t\t*"/bin/sh /init"*) kill -9 "$pid" 2>/dev/null || true ;;\n'
    '\t\tesac\n'
    '\tdone\n'
    '\tsleep 1\n'
    '\tmsg "rubens-initramfs: stopped the background respawn loops"\n'
    '\treturn 0\n'
    '}')
s = s.replace(old_calls, new_calls, 1)

old_switch = ('\t\t\tmsg "rubens-initramfs: switching root to $ROOT_PART ($fsname)"\n'
              '\t\t\texec switch_root /mnt/root /sbin/init')
assert old_switch in s, "找不到 switch_root 调用"
s = s.replace(old_switch,
              '\t\t\tmsg "rubens-initramfs: switching root to $ROOT_PART ($fsname)"\n'
              '\t\t\tkill_old_shells\n'
              '\t\t\texec switch_root /mnt/root /sbin/init', 1)
open(p, 'w').write(s)
print("       已插入 kill_old_shells")
PY
	ok "switch_root 前会清理后台 shell"
else
	ok "kill_old_shells 已存在（幂等）"
fi

# --- 补丁 C: 让 msg() 同时写串口（PITFALLS §8 的观测手段）
# initramfs 的所有进度日志只写 /dev/kmsg 的话，在 USB 串口上完全看不到 ——
# 而串口是启动失败时唯一的观测通道。双写 ttyGS0 成本为零。
if ! grep -q 'dev/ttyGS0 2>/dev/null' "$INIT" || \
   ! sed -n '1,40p' "$INIT" | grep -q 'dev/ttyGS0'; then
	python3 - "$INIT" <<'PY2'
import sys
p = sys.argv[1]
s = open(p).read()
old = "msg() { printf '%s\\n' \"$*\" > /dev/kmsg 2>/dev/null || true; }"
if old in s:
    s = s.replace(old, "\n".join([
        "# Log to the kernel ring buffer AND straight to the CDC-ACM gadget port.",
        "# Writing to ttyGS0 costs nothing when the host is not listening, and it",
        "# means boot progress is visible even before any userspace getty exists.",
        "msg() {",
        "\tprintf '%s\\n' \"$*\" > /dev/kmsg 2>/dev/null || true",
        "\t[ -c /dev/ttyGS0 ] && printf '%s\\n' \"$*\" > /dev/ttyGS0 2>/dev/null",
        "\treturn 0",
        "}",
    ]), 1)
    open(p, 'w').write(s)
    print("       已改为双写 kmsg + ttyGS0")
else:
    print("       msg() 已是双写形式（幂等）")
PY2
	ok "msg() 双写 /dev/kmsg 和 /dev/ttyGS0"
else
	ok "msg() 双写已存在（幂等）"
fi

# --- 补丁 D: switch_root 前在 rootfs 里启用串口 getty
# 如果目标 rootfs 没自带 serial-getty@ttyGS0，切过去之后串口就静默了
# （systemd 接管 PID 1，没有东西读 ttyGS0）。这里在切换前补上符号链接。
if ! grep -q 'setup_serial_getty' "$INIT"; then
	python3 - "$INIT" <<'PY3'
import sys
p = sys.argv[1]
s = open(p).read()
func = "\n".join([
    "",
    "# The rootfs may have been built without a serial getty, so nothing would",
    "# read ttyGS0 once systemd owns PID 1 and the port would go silent.",
    "setup_serial_getty() {",
    "\tunit=/usr/lib/systemd/system/serial-getty@.service",
    "\twant=/etc/systemd/system/getty.target.wants",
    "\t[ -f \"/mnt/root$unit\" ] || {",
    "\t\tmsg \"rubens-initramfs: no serial-getty unit in rootfs\"",
    "\t\treturn 0",
    "\t}",
    "\t[ -L \"/mnt/root$want/serial-getty@ttyGS0.service\" ] && {",
    "\t\tmsg \"rubens-initramfs: serial-getty@ttyGS0 already enabled\"",
    "\t\treturn 0",
    "\t}",
    "\tmount -o remount,rw /mnt/root 2>/dev/null",
    "\tmkdir -p \"/mnt/root$want\" 2>/dev/null",
    "\tif ln -sf \"$unit\" \"/mnt/root$want/serial-getty@ttyGS0.service\" 2>/dev/null; then",
    "\t\tsync",
    "\t\tmsg \"rubens-initramfs: enabled serial-getty@ttyGS0 in the rootfs\"",
    "\tfi",
    "\treturn 0",
    "}",
    "",
    'msg "rubens-initramfs: searching for a bootable rootfs"',
])
anchor = '\nmsg "rubens-initramfs: searching for a bootable rootfs"\n'
assert anchor in s, "找不到 rootfs 搜索锚点"
s = s.replace(anchor, func, 1)
call = "\t\t\tprovision_rootfs\n"
assert call in s, "找不到 provision_rootfs 调用点"
s = s.replace(call, call + "\t\t\tsetup_serial_getty\n", 1)
open(p, 'w').write(s)
print("       已插入 setup_serial_getty")
PY3
	ok "switch_root 前会启用串口 getty"
else
	ok "setup_serial_getty 已存在（幂等）"
fi

bash -n "$INIT" || { bad "/init 语法错误"; exit 1; }
ok "/init 语法正确（$before -> $(stat -c %s "$INIT") 字节）"

hdr "5. 重新打包 ramdisk"
# 可复现打包。cpio 有两个不确定源，实测 --reproducible 只能解决第一个：
#
#   1. 遍历顺序 —— find 的顺序随文件系统而变
#   2. inode 号 —— cpio 会写入 st_ino，而每次在 mktemp 目录里解包后 inode
#      都不同；cpio 的 --reproducible 在本机（GNU cpio 2.15）实测**没能**
#      消除它，产出仍是每次不同
#
# 所以自己写 newc 归档：格式简单（110 字节 ASCII 头 + 文件名 + 内容），
# 且能把 ino / mtime 全部固定。这样输出只取决于文件内容与权限。
python3 - "$WORK/root" "$WORK/new.cpio" <<'PYX'
import os, stat, sys

root, out = sys.argv[1], sys.argv[2]
MAGIC = b'070701'
FIXED_MTIME = 0          # 固定时间戳，消除构建时间的影响

def entries(root):
    """按字典序产出相对路径，保证顺序确定。"""
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        filenames.sort()
        rel = os.path.relpath(dirpath, root)
        yield '.' if rel == '.' else rel
        for name in filenames:
            yield os.path.normpath(os.path.join(rel, name))

def field(v):
    return b'%08X' % (v & 0xFFFFFFFF)

ino = 0
with open(out, 'wb') as fh:
    for rel in entries(root):
        ino += 1
        full = os.path.join(root, rel)
        st = os.lstat(full)
        name = b'.' if rel == '.' else rel.encode()
        mode = st.st_mode

        if stat.S_ISLNK(mode):
            data = os.readlink(full).encode()
        elif stat.S_ISREG(mode):
            data = open(full, 'rb').read()
        else:
            data = b''

        # newc 头：magic + 13 个 8 字节十六进制字段，共 6 + 13*8 = 110 字节
        #   ino, mode, uid, gid, nlink, mtime, filesize,
        #   devmajor, devminor, rdevmajor, rdevminor, namesize, check
        # namesize 必须**包含**结尾的 NUL（内核也照这个读）
        namesize = len(name) + 1
        hdr = (MAGIC
               + field(ino) + field(mode) + field(0) + field(0)
               + field(1) + field(FIXED_MTIME) + field(len(data))
               + field(0) + field(0) + field(0) + field(0)
               + field(namesize) + field(0))
        assert len(hdr) == 110, len(hdr)
        fh.write(hdr)
        fh.write(name + b'\0')
        pad = (-(110 + len(name) + 1)) % 4
        fh.write(b'\0' * pad)
        fh.write(data)
        if stat.S_ISREG(mode):
            fh.write(b'\0' * ((-len(data)) % 4))

    # 结尾标记：一个名为 TRAILER!!! 的空条目
    trailer = b'TRAILER!!!'
    hdr = (MAGIC + field(0) + field(0) + field(0) + field(0)
           + field(1) + field(FIXED_MTIME) + field(0)
           + field(0) + field(0) + field(0) + field(0)
           + field(len(trailer) + 1) + field(0))
    fh.write(hdr)
    fh.write(trailer + b'\0')
    fh.write(b'\0' * ((-(110 + len(trailer) + 1)) % 4))

print(f"       写出 {ino} 个条目")
PYX
ok "已生成确定性 cpio（$(( $(stat -c %s "$WORK/new.cpio") / 1024 )) KiB）"

$LZ4 -l -9 -f "$WORK/new.cpio" "$WORK/new.lz4" 2>/dev/null

RD=$(stat -c %s "$WORK/new.lz4")
if [ "$RD" -gt 4194304 ]; then
	bad "ramdisk $RD 字节超过 ~4 MiB 的 LK 预算"
	exit 1
fi
ok "ramdisk $RD 字节（预算 4194304，占用 $((RD * 100 / 4194304))%）"

magic=$(hex4 "$WORK/new.lz4")
if [ "$magic" = "$LZ4_MAGIC" ]; then
	ok "LZ4 legacy 格式（魔数 $magic）"
else
	bad "ramdisk 魔数是 $magic，期望 $LZ4_MAGIC"
	info "内核的 initramfs 解压器只认 LZ4 legacy —— 见 PITFALLS §10"
	exit 1
fi

hdr "6. 打包 boot.img"
gzip -n -9 -c "$KERNEL" > "$WORK/kernel.gz"
info "内核: $(stat -c %s "$KERNEL") -> gz $(stat -c %s "$WORK/kernel.gz") 字节"

# 打包参数说明：
#   header_version 4      LK 认这个
#   os_version/os_patch   必须 >= 设备原厂值（anti_version=1 的防回滚检查）。
#                         12.0.0 / 2024-09 与 K50 原厂 boot.img 持平，安全。
#   不加 --base 等偏移参数  用 mkbootimg 的默认值即可（与可启动镜像一致）
mkbootimg \
	--header_version 4 \
	--os_version 12.0.0 \
	--os_patch_level 2024-09 \
	--kernel "$WORK/kernel.gz" \
	--ramdisk "$WORK/new.lz4" \
	--output "$OUT" || { bad "mkbootimg 失败"; exit 1; }

# boot_signature_size（偏移 1580）LK 会读取，必须为 0x1000
python3 - "$OUT" <<'PY'
import struct, sys
p = sys.argv[1]
d = bytearray(open(p, 'rb').read())
struct.pack_into('<I', d, 1580, 0x1000)
open(p, 'wb').write(d)
print("       boot_signature_size -> 0x1000")
PY
ok "已生成 $(basename "$OUT")  ($(stat -c %s "$OUT") 字节)"

hdr "7. 回读校验"
V=$(mktemp -d "$WORK/verify-XXXXXX")
unpack_bootimg --boot_img "$OUT" --out "$V" >/dev/null 2>&1 || {
	bad "unpack_bootimg 失败"; exit 1; }

gzip -dc "$V/kernel" > "$V/k" 2>/dev/null
if cmp -s "$V/k" "$KERNEL"; then ok "内核逐字节一致"
else bad "内核不一致"; exit 1; fi

if [ "$(hex4 "$V/ramdisk")" = "$LZ4_MAGIC" ]; then
	ok "ramdisk 是 LZ4 legacy"
else
	bad "ramdisk 格式错误"; exit 1
fi

$LZ4 -l -d -f "$V/ramdisk" "$V/rd.cpio" >/dev/null 2>&1
mkdir -p "$V/x" && (cd "$V/x" && cpio -idm < "$V/rd.cpio") >/dev/null 2>&1
if [ -x "$V/x/init" ] && ! grep -q basename "$V/x/init" && \
   grep -q kill_old_shells "$V/x/init"; then
	ok "ramdisk 里的 /init 含两个必需补丁"
else
	bad "回读的 /init 不对"; exit 1
fi

for rel in arm/mali/arch10.8/mali_csffw.bin conninfra.cfg; do
	if [ -f "$V/x/lib/firmware/$rel" ]; then
		ok "ramdisk 含 $rel"
	else
		bad "ramdisk 缺 $rel"; exit 1
	fi
done

if [ "$(stat -c %s "$OUT")" -lt 67108864 ]; then
	ok "大小 $(stat -c %s "$OUT") < boot 分区 64 MiB"
else
	bad "超出 boot 分区容量"; exit 1
fi

hdr "总结"
cat <<EOF

  $(basename "$OUT") 已就绪
  sha256: $(sha256sum "$OUT" | cut -d' ' -f1)

  刷入（需要设备已在 fastboot）:
    fastboot flash boot_a $(basename "$OUT")
    fastboot reboot

  只刷 boot 分区不会影响 userdata 上的系统。
EOF
