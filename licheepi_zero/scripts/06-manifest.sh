#!/bin/bash
# ---------------------------------------------------------------------------
# 06 生成产物清单（sha256）+ 体积/分区占用检查
# ---------------------------------------------------------------------------
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/env.sh"
script_init "$(basename "${BASH_SOURCE[0]}" .sh)"

MAN="$OUT/MANIFEST.txt"
{
	echo "# LicheePi Zero Dock (V3s) 构建产物清单"
	echo "# 生成时间: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "# U-Boot $UBOOT_VER / Linux $KERNEL_VER / Alpine $ALPINE_VER"
	echo "#"
	printf '# %-38s %10s  %-10s %s\n' 文件 大小 烧录偏移 sha256
	for spec in \
		"u-boot-sunxi-with-spl.bin:$UBOOT_OFF:$UBOOT_SIZE" \
		"zImage:$KERNEL_OFF:$KERNEL_SIZE" \
		"sun8i-v3s-licheepi-zero-dock.dtb:$DTB_OFF:$DTB_SIZE" \
		"rootfs.ubi:$ROOTFS_OFF:$ROOTFS_SIZE" ; do
		f=${spec%%:*}; rest=${spec#*:}; off=${rest%%:*}; psz=${rest##*:}
		[ -f "$OUT/$f" ] || continue
		s=$(size "$OUT/$f")
		used=$(( s * 100 / psz ))
		printf '%-40s %10d  %-10s %s  (占用分区 %d%%)\n' \
			"$f" "$s" "$(hex "$off")" "$(sha256sum "$OUT/$f" | cut -d' ' -f1)" "$used"
	done
	# 不进 NOR、直接 scp 到板子跑的产物（LVGL demo）
	for f in lvgl-monitor; do
		[ -f "$OUT/$f" ] || continue
		printf '%-40s %10d  %-10s %s  (%s)\n' \
			"$f" "$(size "$OUT/$f")" "—" "$(sha256sum "$OUT/$f" | cut -d' ' -f1)" \
			"scp 到板子运行，不烧 NOR"
	done
} > "$MAN"

# ---- 分区对齐检查 ----
# 参考 Sipeed wiki《SPI Flash 系统编译》：每个分区的大小/偏移必须是擦除块（64 KiB）的整数倍，
# 否则擦除、UBI PEB 划分都会出问题（UBI 还要求 PEB 边界对齐）。
log "分区对齐检查（擦除块 $((${UBI_PEB_SIZE:-65536} / 1024)) KiB）"
ERASE=${UBI_PEB_SIZE:-65536}
align_bad=0
for spec in "u-boot:$UBOOT_OFF:$UBOOT_SIZE" "kernel:$KERNEL_OFF:$KERNEL_SIZE" \
            "dtb:$DTB_OFF:$DTB_SIZE" "rootfs:$ROOTFS_OFF:$ROOTFS_SIZE"; do
	pname=${spec%%:*}; rest=${spec#*:}; poff=${rest%%:*}; psz=${rest##*:}
	if [ $((poff % ERASE)) -ne 0 ] || [ $((psz % ERASE)) -ne 0 ]; then
		warn "分区 $pname 未按擦除块对齐：偏移 $(hex "$poff") 大小 $(hex "$psz")"
		align_bad=1
	else
		printf '  %-8s 偏移 %-10s 大小 %-10s ✓\n' "$pname" "$(hex "$poff")" "$(hex "$psz")"
	fi
done
[ "$align_bad" = 0 ] || die "分区必须按 64 KiB 擦除块对齐，请改 board/layout.conf"

# ---- 交叉检查：U-Boot 与内核设备树里的 SPI NOR 分区必须一致 ----
KDTB="$OUT/sun8i-v3s-licheepi-zero-dock.dtb"
UDTB="$UBOOT_DIR/u-boot.dtb"
if [ -f "$KDTB" ] && [ -f "$UDTB" ]; then
	part_of() { dtc -I dtb -O dts "$1" 2>/dev/null | sed -n '/flash@0/,/^\t\t\t};/p' | grep -E 'label|reg = <0x[0-9a-f]+ 0x[0-9a-f]+>'; }
	if diff -q <(part_of "$KDTB") <(part_of "$UDTB") >/dev/null; then
		echo "==> 分区一致性检查：内核 dtb 与 u-boot.dtb 的 SPI NOR 分区一致 ✓"
	else
		warn "内核 dtb 与 u-boot.dtb 的 SPI NOR 分区不一致！"
		diff <(part_of "$KDTB") <(part_of "$UDTB") | sed 's/^/    /'
	fi
fi

cat "$MAN"
log "06 完成：out/MANIFEST.txt"
