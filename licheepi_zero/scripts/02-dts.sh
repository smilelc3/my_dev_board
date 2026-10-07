#!/bin/bash
# ---------------------------------------------------------------------------
# 02 由 board/layout.conf 生成板级片段，追加到 U-Boot 与内核两份 dts
# 幂等（靠 BEGIN 标记剥离旧内容）；追加后逐字比对两份片段，保证分区表一致
# ---------------------------------------------------------------------------
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/env.sh"
script_init "$(basename "${BASH_SOURCE[0]}" .sh)"

TPL="$BOARD/licheepi-dock-nor.dtsi.in"
FRAG="$WORK/licheepi-dock-nor.dtsi"

DTS_UBOOT="$UBOOT_DIR/dts/upstream/src/arm/allwinner/sun8i-v3s-licheepi-zero-dock.dts"
DTS_LINUX="$LINUX_DIR/arch/arm/boot/dts/allwinner/sun8i-v3s-licheepi-zero-dock.dts"

log "02 从 layout.conf 生成设备树片段"
[ -f "$TPL" ] || die "找不到模板 $TPL"
node() { printf '%x' "$1"; }           # partition@<hex> 节点名
sed -e "s/@UBOOT_OFF@/$(hex $UBOOT_OFF)/g"     -e "s/@UBOOT_SIZE@/$(hex $UBOOT_SIZE)/g" \
    -e "s/@UBOOT_NODE@/$(node $UBOOT_OFF)/g" \
    -e "s/@KERNEL_OFF@/$(hex $KERNEL_OFF)/g"   -e "s/@KERNEL_SIZE@/$(hex $KERNEL_SIZE)/g" \
    -e "s/@KERNEL_NODE@/$(node $KERNEL_OFF)/g" \
    -e "s/@DTB_OFF@/$(hex $DTB_OFF)/g"         -e "s/@DTB_SIZE@/$(hex $DTB_SIZE)/g" \
    -e "s/@DTB_NODE@/$(node $DTB_OFF)/g" \
    -e "s/@ROOTFS_OFF@/$(hex $ROOTFS_OFF)/g"   -e "s/@ROOTFS_SIZE@/$(hex $ROOTFS_SIZE)/g" \
    -e "s/@ROOTFS_NODE@/$(node $ROOTFS_OFF)/g" \
    "$TPL" > "$FRAG"
grep -q '@[A-Z_]*@' "$FRAG" && die "模板里还有没替换的占位符：$(grep -o '@[A-Z_]*@' "$FRAG" | sort -u | tr '\n' ' ')"

strip_fragment() {   # 去掉之前追加的片段（有 BEGIN 标记用它，否则按注释块特征找）
	local f=$1 ln="" l
	ln=$(grep -n 'LICHEEPI-BOARD-FRAGMENT-BEGIN' "$f" 2>/dev/null | head -1 | cut -d: -f1 || true)
	if [ -z "$ln" ]; then
		for l in $(grep -n '^/\*$' "$f" 2>/dev/null | cut -d: -f1 || true); do
			if sed -n "$((l + 1))p" "$f" | grep -q 'LicheePi Zero Dock'; then
				ln=$l; break
			fi
		done
	fi
	if [ -n "$ln" ]; then
		head -n "$((ln - 1))" "$f" > "$f.tmp"
		mv "$f.tmp" "$f"
		echo "  [--] 已剥离旧片段：$f"
	fi
}

patch_dts() {
	local f=$1
	[ -f "$f" ] || die "找不到 $f"
	strip_fragment "$f"
	echo "  [++] 追加板级片段：$f"
	{ echo; cat "$FRAG"; } >> "$f"
}

patch_dts "$DTS_UBOOT"
patch_dts "$DTS_LINUX"

# 基树本身可能不同（U-Boot 的 dts 是某版 Linux 同步来的），只要求追加的片段一致
frag_uboot=$(sed -n '/LICHEEPI-BOARD-FRAGMENT-BEGIN/,$p' "$DTS_UBOOT")
frag_linux=$(sed -n '/LICHEEPI-BOARD-FRAGMENT-BEGIN/,$p' "$DTS_LINUX")
if [ "$frag_uboot" = "$frag_linux" ] && [ -n "$frag_uboot" ]; then
	log "02 完成：设备树片段已生成并追加（分区 $(hex $UBOOT_OFF)/$(hex $KERNEL_OFF)/$(hex $DTB_OFF)/$(hex $ROOTFS_OFF)）"
else
	die "两份 dts 的板级片段不一致"
fi
