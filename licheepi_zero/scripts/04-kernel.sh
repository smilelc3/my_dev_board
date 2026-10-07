#!/bin/bash
# ---------------------------------------------------------------------------
# 04 构建内核 + 设备树：sunxi_defconfig + board/kernel-nor.fragment
# 产出 out/zImage 与 out/sun8i-v3s-licheepi-zero-dock.dtb
# ---------------------------------------------------------------------------
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/env.sh"
script_init 04-kernel

cp "$BOARD/kernel-nor.fragment" "$WORK/kernel-nor.fragment"

log "04 构建 Linux $KERNEL_VER"
cd "$LINUX_DIR"
make distclean >/dev/null 2>&1 || true
make sunxi_defconfig >"$LOG" 2>&1
./scripts/kconfig/merge_config.sh -m .config "$WORK/kernel-nor.fragment" >>"$LOG" 2>&1 || true
make olddefconfig >>"$LOG" 2>&1
make -j"$(nproc)" zImage dtbs >>"$LOG" 2>&1

ZIMAGE=arch/arm/boot/zImage
DTB=arch/arm/boot/dts/allwinner/sun8i-v3s-licheepi-zero-dock.dtb
ls -l "$ZIMAGE" "$DTB" | awk '{printf "  %-64s %8d bytes\n", $9, $5}'

ZSZ=$(size "$ZIMAGE"); DSZ=$(size "$DTB")
[ "$ZSZ" -le "$((KERNEL_SIZE))" ] || die "zImage $ZSZ 超出内核分区 $KERNEL_SIZE"
[ "$DSZ" -le "$((DTB_SIZE))" ]    || die "dtb $DSZ 超出 dtb 分区 $DTB_SIZE"

install -m644 "$ZIMAGE" "$OUT/zImage"
install -m644 "$DTB"    "$OUT/sun8i-v3s-licheepi-zero-dock.dtb"
log "04 完成：out/zImage ($ZSZ bytes), out/sun8i-v3s-licheepi-zero-dock.dtb ($DSZ bytes)"
