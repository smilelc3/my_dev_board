#!/bin/bash
# ---------------------------------------------------------------------------
# 03 构建 U-Boot（V3s / SPI NOR 启动）
# 产出 out/u-boot-sunxi-with-spl.bin：SPL@0x0 + u-boot@0x8000 + 环境@0xF0000
# ---------------------------------------------------------------------------
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/env.sh"
script_init 03-uboot

# merge_config.sh 用未加引号的 $MERGED_FILES 展开，路径带空格会散架 —— 先拷到无空格目录
cp "$BOARD/uboot-nor.fragment" "$WORK/uboot-nor.fragment"

log "03 构建 U-Boot $UBOOT_VER"
cd "$UBOOT_DIR"
make distclean >/dev/null 2>&1 || true
make LicheePi_Zero_defconfig >"$LOG" 2>&1
./scripts/kconfig/merge_config.sh -m .config "$WORK/uboot-nor.fragment" >>"$LOG" 2>&1
make olddefconfig >>"$LOG" 2>&1
make -j"$(nproc)" >>"$LOG" 2>&1

for f in spl/u-boot-spl.bin u-boot.bin u-boot-sunxi-with-spl.bin u-boot.dtb; do
	[ -f "$f" ] && printf '  %-28s %8d bytes\n' "$f" "$(size "$f")"
done

SZ=$(size u-boot-sunxi-with-spl.bin)
[ "$SZ" -le "$((UBOOT_MAX_IMAGE))" ] || die "u-boot 镜像 $SZ 超过 $UBOOT_MAX_IMAGE（会盖到环境变量区）"
[ "$SZ" -le "$((UBOOT_SIZE))" ] || die "u-boot 镜像超出分区"

install -m644 u-boot-sunxi-with-spl.bin "$OUT/u-boot-sunxi-with-spl.bin"
log "03 完成：out/u-boot-sunxi-with-spl.bin ($SZ bytes)"
