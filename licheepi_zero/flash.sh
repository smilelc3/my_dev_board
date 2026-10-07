#!/bin/bash
# ===========================================================================
# 烧录 / 更新 / 校验 32 MiB SPI NOR（MX25L25645G）
#
#  A. 通过 USB FEL (linux-sunxi/sunxi-tools)：
#   ./flash.sh info          查看 FEL 设备、flash 信息、分区规划、本地镜像
#   ./flash.sh write-images  写 kernel + dtb + rootfs.ubi（不动引导区，随时可回 FEL）
#   ./flash.sh write-rootfs  只重写 rootfs（UBI 镜像）
#   ./flash.sh write-uboot   只写 u-boot 分区（0x0，最后一步）
#   ./flash.sh write-all     write-images + write-uboot
#   ./flash.sh readback      读回各分区与本地文件比对 sha256
#   ./flash.sh fel-boot      用 sunxi-fel 把 U-Boot 载入内存启动（完全不写 NOR，用于验证）
#   ./flash.sh wipe-rootfs   擦掉 rootfs 分区（重新烧 UBI 前想干净一点时用）
#   ./flash.sh force-fel     擦掉 u-boot 分区头部 => 下次上电自动进 FEL（救援）
#   ./flash.sh backup [file] 整片备份
#   ./flash.sh check-32m     只读自检：验证 16 MiB 以上能正确寻址（需要 FEL + 已打 4 字节补丁）
#
#  说明：上游 sunxi-fel 只发 3 字节地址，越过 16 MiB 会静默回绕覆盖前面的数据。
#        本仓库给 sunxi-tools 打了 4 字节专用 opcode 补丁（00-host-tools.sh 自动应用），
#        0x13/0x12/0x21/0xDC 自带地址且不改变芯片状态，所以整片 32 MiB 都能烧，
#        复位后 BROM 仍能读到偏移 0 的 eGON 头（不像 EN4B 切了必须断电）。
# ===========================================================================
set -euo pipefail
HERE="$(dirname "$(readlink -f "$0")")"
source "$HERE/scripts/env.sh"

FEL="$SUNXI_TOOLS/sunxi-fel"
TMP="$WORK/flash"; mkdir -p "$TMP"

UBOOT_IMG="$OUT/u-boot-sunxi-with-spl.bin"
ZIMAGE="$OUT/zImage"
DTB="$OUT/sun8i-v3s-licheepi-zero-dock.dtb"
ROOTFS="$OUT/rootfs.ubi"

need() { [ -f "$1" ] || die "缺少 $1（先跑 ./build.sh）"; }

usage() { awk 'NR>1 { if (/^#/) { sub(/^# ?/, ""); print } else exit }' "$0"; }

fel_write() { # offset file
	echo "  --> 写入 $(basename "$2") -> NOR $(hex "$1") ($(( $1 / 1024 )) KiB), $(($(size "$2")/1024)) KiB"
	"$FEL" -p spiflash-write "$1" "$2"
}

fel_verify() { # offset file
	local off=$1 f=$2 sz a b
	sz=$(size "$f")
	"$FEL" spiflash-read "$off" "$sz" "$TMP/readback.bin" >/dev/null 2>&1
	a=$(sha256sum "$f" | cut -d' ' -f1)
	b=$(sha256sum "$TMP/readback.bin" | cut -d' ' -f1)
	if [ "$a" = "$b" ]; then
		echo "  [ok] $(basename "$f") @ $(hex "$off")  sha256=${a:0:16}…"
	else
		echo "  [!!] $(basename "$f") @ $(hex "$off")  校验失败"
		return 1
	fi
}

cmd_info() {
	echo "== FEL 设备 =="
	"$FEL" ver
	echo; "$FEL" spiflash-info
	echo; echo "== 分区规划（32 MiB SPI NOR, MX25L25645G）=="
	printf '  %-8s %-10s %-10s %s\n' 名称 偏移 大小 内容
	printf '  %-8s %-10s %-10s %s\n' u-boot   "$(hex $UBOOT_OFF)"  "$(hex $UBOOT_SIZE)"  "SPL@0 + u-boot@0x8000 + 环境@$(hex $ENV_OFF)"
	printf '  %-8s %-10s %-10s %s\n' kernel   "$(hex $KERNEL_OFF)" "$(hex $KERNEL_SIZE)" "zImage"
	printf '  %-8s %-10s %-10s %s\n' dtb      "$(hex $DTB_OFF)"    "$(hex $DTB_SIZE)"    "设备树"
	printf '  %-8s %-10s %-10s %s\n' rootfs   "$(hex $ROOTFS_OFF)" "$(hex $ROOTFS_SIZE)" "UBI 卷 rootfs（UBIFS，autoresize）"
	echo; echo "== 本地镜像 =="
	for f in "$UBOOT_IMG" "$ZIMAGE" "$DTB" "$ROOTFS"; do
		[ -f "$f" ] && printf '  %-42s %9d bytes\n' "$(basename "$f")" "$(size "$f")"
	done
}

# ---------------------------------------------------------------------------
# 重烧 rootfs 时的"旧 UBI 残留"处理：镜像只覆盖自己那几 MiB，分区剩下的部分
# 若留上一次的 PEB，而 ubinize -Q 固定了 image sequence number，新旧会被当成
# 同一镜像 -> 内核报 "unable to mount root fs on ubi0:rootfs"。
# 所以写之前先采样检查未覆盖区间，脏就整段擦成 0xFF。
# ---------------------------------------------------------------------------
rootfs_tail_range() { # 输出 "起始 结束"
	local start=$((ROOTFS_OFF + $(size "$ROOTFS")))
	local end=$((ROOTFS_OFF + ROOTFS_SIZE))
	[ "$start" -lt "$end" ] || return 1
	echo "$start $end"
}

rootfs_tail_dirty() {
	local range start end step i off
	range=$(rootfs_tail_range) || return 1
	start=${range%% *}; end=${range##* }
	step=$(( (end - start) / 16 ))
	[ "$step" -lt 4096 ] && step=4096
	for i in $(seq 0 15); do
		off=$((start + i * step))
		[ "$off" -ge "$end" ] && break
		"$FEL" spiflash-read "$off" 4096 "$TMP/tail.bin" >/dev/null 2>&1 || return 0
		# 只要有一个字节不是 0xFF 就算脏
		if [ -n "$(od -An -tx1 -v "$TMP/tail.bin" | tr -d ' \n' | tr -d 'f')" ]; then
			echo "  未覆盖区间 $(hex "$off") 处不是空的（旧 UBI 残留）" >&2
			return 0
		fi
	done
	return 1
}

rootfs_wipe_tail() {
	local range start end off chunk=65536
	range=$(rootfs_tail_range) || return 0
	start=${range%% *}; end=${range##* }
	log "  擦除镜像未覆盖的 $(hex "$start")..$(hex "$end")（$(( (end-start)/1024 )) KiB，约 $(( (end-start)/71680 )) 秒）"
	python3 -c "import sys; sys.stdout.buffer.write(b'\xff' * $chunk)" > "$TMP/ff64k.bin"
	off=$start
	while [ "$off" -lt "$end" ]; do
		"$FEL" spiflash-write "$off" "$TMP/ff64k.bin" >/dev/null 2>&1
		off=$((off + chunk))
	done
	log "  擦除完成"
}

rootfs_prepare() { # 写 UBI 镜像前的统一入口
	need "$ROOTFS"
	if [ "${SKIP_ROOTFS_TAIL_WIPE:-0}" = 1 ]; then
		warn "SKIP_ROOTFS_TAIL_WIPE=1：跳过旧 UBI 残留检查（只有确认分区是空的时候才这么用）"
		return 0
	fi
	if rootfs_tail_dirty; then
		rootfs_wipe_tail
	else
		log "  镜像未覆盖的区间是空的，无需擦除"
	fi
}

cmd_write_images() {
	need "$ZIMAGE"; need "$DTB"; need "$ROOTFS"
	echo "== 写 kernel / dtb / rootfs（保留 u-boot 分区不动）=="
	fel_write "$KERNEL_OFF" "$ZIMAGE"
	fel_write "$DTB_OFF"    "$DTB"
	rootfs_prepare
	fel_write "$ROOTFS_OFF" "$ROOTFS"
	echo "== 校验 =="
	fel_verify "$KERNEL_OFF" "$ZIMAGE"
	fel_verify "$DTB_OFF"    "$DTB"
	fel_verify "$ROOTFS_OFF" "$ROOTFS"
	echo
	echo "现在可以："
	echo "  ./flash.sh fel-boot     在内存里试启动（不写 NOR，失败按复位就回 FEL）"
	echo "  ./flash.sh write-uboot  把引导写进 NOR"
}

cmd_write_rootfs() {
	need "$ROOTFS"
	echo "== 只重写 rootfs 分区（UBI 镜像）=="
	rootfs_prepare
	fel_write "$ROOTFS_OFF" "$ROOTFS"
	fel_verify "$ROOTFS_OFF" "$ROOTFS"
	echo "完成：复位后 UBI 按新卷表挂载，UBIFS 首次挂载自动扩到卷大小（$(hex $((ROOTFS_SIZE)))/64KiB 分区的绝大部分）。"
}


cmd_write_uboot() {
	need "$UBOOT_IMG"
	echo "== 写 u-boot 分区（SPL 位于 NOR 偏移 0）=="
	fel_write "$UBOOT_OFF" "$UBOOT_IMG"
	fel_verify "$UBOOT_OFF" "$UBOOT_IMG"
	echo "完成：复位板子即可从 NOR 独立启动。"
}

cmd_readback() {
	echo "== 读回校验 =="
	fel_verify "$KERNEL_OFF" "$ZIMAGE"
	fel_verify "$DTB_OFF"    "$DTB"
	[ -f "$UBOOT_IMG" ] && fel_verify "$UBOOT_OFF" "$UBOOT_IMG" || true
	if ! fel_verify "$ROOTFS_OFF" "$ROOTFS"; then
		echo "    注意：rootfs 是可写 UBIFS，板子第一次启动后 UBI 会重写布局卷"
		echo "    （autoresize 撑满卷 + 更新擦除计数），所以启动过的板子这里必然对不上。"
		echo "    要校验镜像请在 write-images 之后、启动之前做。"
	fi
}

cmd_fel_boot() {
	need "$UBOOT_IMG"
	echo "== 通过 FEL 把 U-Boot 装进内存启动（不写 NOR）=="
	echo "   U-Boot 会按 bootcmd 从 NOR 读 kernel/dtb 并 bootz。"
	echo "   若失败，按板子复位键即可回到 FEL（NOR 里的引导区保持原样）。"
	exec "$FEL" -p uboot "$UBOOT_IMG"
}

cmd_wipe_rootfs() {
	echo "== 擦除 rootfs 分区（$(hex $ROOTFS_OFF), $(($ROOTFS_SIZE/1024)) KiB，跨过 16 MiB 边界，需要 4 字节 opcode 补丁）=="
	python3 -c "import sys; sys.stdout.buffer.write(b'\xff' * $((ROOTFS_SIZE)))" > "$TMP/blank.bin"
	"$FEL" -p spiflash-write "$ROOTFS_OFF" "$TMP/blank.bin"
	echo "完成。"
}

cmd_force_fel() {
	echo "== 擦除 NOR 偏移 0 起 64 KiB（u-boot 分区头部）=="
	python3 -c "import sys; sys.stdout.buffer.write(b'\xff' * 65536)" > "$TMP/blank64k.bin"
	"$FEL" -p spiflash-write 0 "$TMP/blank64k.bin"
	echo "完成：下次上电 BROM 找不到 eGON 镜像，会自动进入 FEL。"
}

cmd_check_32m() {
	echo "== 32 MiB 寻址自检（只读，不动 flash 内容）=="
	"$FEL" spiflash-info || die "没找到 FEL 设备（先 ./flash.sh force-fel 并重启）"
	echo
	echo "  判据：rootfs 是 UBI，每个 PEB（64 KiB）开头都有 EC 头，magic = 0x55424923（"UBI#"）。"
	echo "        0x1000000 / 0x1400000 / 0x1800000 / 0x1FF0000 都是 PEB 边界，"
	echo "        用 4 字节地址读应该读到这个 magic；"
	echo "        若读到 eGON 头（000000ea…）或全 FF，说明还在按 3 字节地址回绕（补丁没生效）。"
	local off hex ok=0
	for off in 0x1000000 0x1400000 0x1800000 0x1FF0000; do
		if "$FEL" spiflash-read "$off" 16 "$TMP/probe.bin" >/dev/null 2>&1; then
			hex=$(od -An -tx1 -N4 "$TMP/probe.bin" | tr -d ' \n')
			if [ "$hex" = "55424923" ]; then
				printf '  %-10s magic=UBI# ✓\n' "$(hex "$off")"
				ok=$((ok + 1))
			else
				printf '  %-10s magic=%s ✗（期望 55424923）\n' "$(hex "$off")" "$hex"
			fi
		else
			printf '  %-10s 读取失败 ✗\n' "$(hex "$off")"
		fi
	done
	echo
	if [ "$ok" -eq 4 ]; then
		echo "==> 4 字节地址读写可用：整个 32 MiB 都能正确寻址（$ok/4）"
	else
		die "16 MiB 以上没能全部读到 UBI magic（$ok/4）：检查 sunxi-fel 是否是本仓库编出来的（grep opcode_4b $SUNXI_TOOLS/fel-spiflash.c）"
	fi
}

cmd_backup() {
	local out=${1:-$OUT/nor-backup/nor-full-$(date +%Y%m%d-%H%M%S).bin}
	mkdir -p "$(dirname "$out")"
	echo "== 整片备份 $((FLASH_TOTAL / 1048576)) MiB -> $out（FEL 读比较慢）=="
	"$FEL" -p spiflash-read 0 "$((FLASH_TOTAL))" "$out"
	echo "完成：$out ($(size "$out") bytes)"
}

case "${1:-info}" in
	info)         cmd_info ;;
	write-images) cmd_write_images ;;
	write-rootfs) cmd_write_rootfs ;;
	write-uboot)  cmd_write_uboot ;;
	write-all|full) cmd_write_images; cmd_write_uboot ;;
	readback)     cmd_readback ;;
	fel-boot)     cmd_fel_boot ;;
	wipe-rootfs)  cmd_wipe_rootfs ;;
	force-fel)    cmd_force_fel ;;
	check-32m)    cmd_check_32m ;;
	backup)       shift; cmd_backup "$@" ;;
	help|-h|--help) usage; exit 0 ;;
	*)            usage; exit 1 ;;
esac
