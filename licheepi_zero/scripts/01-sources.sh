#!/bin/bash
# ---------------------------------------------------------------------------
# 01 下载并校验上游源码
#   U-Boot   $UBOOT_VER   (ftp.denx.de)
#   Linux    $KERNEL_VER  (kernel.org 镜像)
#   Alpine   $ALPINE_VER  (dl-cdn.alpinelinux.org)
#   LVGL     $LVGL_VER    (github.com/lvgl/lvgl，给 demo/lvgl-monitor 用)
#   libdrm   $LIBDRM_VER  (dri.freedesktop.org，DRM 后端；只编它的核心)
#   Noto SC  $CJK_FONT_FILE (中文子集字体的源字体，4bpp 字模由 mkfont.py 生成)
# sha256 记录在 board/sources.lock，校验不过就报错，保证可复现。
# ---------------------------------------------------------------------------
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/env.sh"
script_init "$(basename "${BASH_SOURCE[0]}" .sh)"

LOCK="$BOARD/sources.lock"
mkdir -p "$SRC"

UBOOT_TAR="$SRC/u-boot-$UBOOT_VER.tar.bz2"
KERNEL_TAR="$SRC/linux-$KERNEL_VER.tar.xz"
ALPINE_TAR="$SRC/alpine-minirootfs-$ALPINE_VER-$ALPINE_ARCH.tar.gz"
LVGL_TAR="$SRC/lvgl-$LVGL_VER.tar.gz"
LIBDRM_TAR="$SRC/libdrm-$LIBDRM_VER.tar.xz"
CJK_FONT_TAR=""   # 字体不是压缩包，直接落到 $CJK_FONT

UBOOT_URL="https://ftp.denx.de/pub/u-boot/u-boot-$UBOOT_VER.tar.bz2"
# 内核镜像有多个，按顺序试（每个 fetch 失败就换下一个）。
# 实测国内网络下 aliyun 的 linux-kernel 镜像有时慢到不可用（1 分钟几 MB），
# 而清华/官方 kernel.org 正常；反之在别的网络里 aliyun 最快，所以做成回退列表。
KERNEL_URLS=(
	"https://mirrors.tuna.tsinghua.edu.cn/kernel/v${KERNEL_VER%%.*}.x/linux-$KERNEL_VER.tar.xz"
	"https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_VER%%.*}.x/linux-$KERNEL_VER.tar.xz"
	"https://mirrors.aliyun.com/linux-kernel/v${KERNEL_VER%%.*}.x/linux-$KERNEL_VER.tar.xz"
)
KERNEL_URL="${KERNEL_URLS[0]}"        # 兼容旧引用：默认镜像
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/releases/$ALPINE_ARCH/alpine-minirootfs-$ALPINE_VER-$ALPINE_ARCH.tar.gz"
LVGL_URL="https://github.com/lvgl/lvgl/archive/refs/tags/v$LVGL_VER.tar.gz"
LIBDRM_URL="https://dri.freedesktop.org/libdrm/libdrm-$LIBDRM_VER.tar.xz"
CJK_FONT_URL="https://raw.githubusercontent.com/notofonts/noto-cjk/main/Sans/SubsetOTF/SC/$CJK_FONT_FILE"

fetch_one() { # url dest name
	local url=$1 dest=$2 name=$3
	# -c 断点续传：上一个镜像下了一半也能接着下；
	# --tries/--timeout 限制重试，镜像挂了要尽快换下一个而不是卡 20 次重试
	wget -c -q --show-progress --tries=3 --timeout=30 -O "$dest.part" "$url"
	mv "$dest.part" "$dest"
	verify "$dest" "$name"
}

fetch() { # url... dest name   （给多个 url 时按顺序回退）
	local args=("$@")
	local name="${args[${#args[@]}-1]}"
	local dest="${args[${#args[@]}-2]}"
	local urls=("${args[@]:0:${#args[@]}-2}")
	if [ -s "$dest" ] && verify "$dest" "$name"; then
		log "$name 已存在且校验通过"
		return
	fi
	local u
	for u in "${urls[@]}"; do
		log "下载 $name  ←  $u"
		if fetch_one "$u" "$dest" "$name"; then
			return 0
		fi
		warn "$name 从 $u 下载/校验失败，换下一个镜像"
	done
	die "$name 所有镜像都失败（sha256 必须与 board/sources.lock 一致）"
}

verify() { # file name
	local sum want
	[ -f "$LOCK" ] || return 1
	want=$(awk -v n="$2" '$2==n {print $1}' "$LOCK")
	[ -n "$want" ] || return 1
	sum=$(sha256sum "$1" | cut -d' ' -f1)
	[ "$sum" = "$want" ]
}

fetch "$UBOOT_URL"  "$UBOOT_TAR"  "u-boot-$UBOOT_VER.tar.bz2"
fetch "${KERNEL_URLS[@]}" "$KERNEL_TAR" "linux-$KERNEL_VER.tar.xz"
fetch "$ALPINE_URL" "$ALPINE_TAR" "alpine-minirootfs-$ALPINE_VER-$ALPINE_ARCH.tar.gz"
fetch "$LVGL_URL"   "$LVGL_TAR"   "lvgl-$LVGL_VER.tar.gz"
fetch "$LIBDRM_URL" "$LIBDRM_TAR" "libdrm-$LIBDRM_VER.tar.xz"
fetch "$CJK_FONT_URL" "$CJK_FONT" "$CJK_FONT_FILE"

for t in "$UBOOT_TAR:$UBOOT_DIR" "$KERNEL_TAR:$LINUX_DIR" "$LVGL_TAR:$LVGL_DIR" "$LIBDRM_TAR:$LIBDRM_DIR"; do
	tar_file=${t%%:*}; dir=${t##*:}
	if [ ! -d "$dir" ]; then
		log "解包 $(basename "$tar_file")"
		tar -xf "$tar_file" -C "$SRC"
	fi
done

[ -d "$SUNXI_TOOLS" ] || { log "克隆 sunxi-tools"; git clone --depth 1 -q https://github.com/linux-sunxi/sunxi-tools.git "$SUNXI_TOOLS"; }

# ---- 给 U-Boot / 内核打本地补丁（幂等）----
# MX25L25635/45G 支持 4 字节地址专用 opcode；强制打开 SPI_NOR_4B_OPCODES，
# 这样 U-Boot 与内核都不会发 EN4B —— 那个模式热复位不清除，切了之后
# BROM（3 字节地址）读不到引导区，板子必须断电才能恢复。
#
# 判"有没有打过"的标记取**补丁自带的独有文本**（注释里那句 + 紧随其后的条目开头）：
# 改补丁的注释时这两行会一起改，所以标记不会和补丁脱节。
# 注意别写成"在条目附近若干行里 grep 4B_OPCODES"——相邻芯片本来就有这个 flag，会假阳性。
if ! grep -q '打开 4B_OPCODES，别发 EN4B' "$UBOOT_DIR/drivers/mtd/spi/spi-nor-ids.c"; then
	log "  给 U-Boot 打 4 字节 opcode 补丁"
	( cd "$UBOOT_DIR" && patch -p1 < "$BOARD/patches/uboot-mx25l256-4b-opcodes.patch" >/dev/null )
fi
if ! grep -q '直接声明 4 字节 opcode，不走 EN4B' "$LINUX_DIR/drivers/mtd/spi-nor/macronix.c"; then
	log "  给内核打 4 字节 opcode 补丁"
	( cd "$LINUX_DIR" && patch -p1 < "$BOARD/patches/linux-mx25l256-4b-opcodes.patch" >/dev/null )
fi

# ---- LVGL：DRM 驱动本地补丁（幂等）----
# 板子上 fbcon 用的 DRM fbdev plane 一直挂在同一个 CRTC 上、zpos 还比 LVGL 的 plane 高，
# 于是 LVGL 画出来的画面被压在下面，屏幕上还是 tty。补丁在首次 atomic 提交里
# 把其它 plane 从该 CRTC 上摘掉。
if ! grep -q 'drm_disable_other_planes' "$LVGL_DIR/src/drivers/display/drm/lv_linux_drm.c"; then
	log "  给 LVGL 的 DRM 驱动打补丁（隐藏同 CRTC 上 fbcon 的 plane）"
	( cd "$LVGL_DIR" && patch -p1 < "$BOARD/patches/lvgl-drm-hide-other-planes.patch" >/dev/null )
fi

log "01 完成：源码就绪"
ls -1d "$UBOOT_DIR" "$LINUX_DIR" "$SUNXI_TOOLS" "$LVGL_DIR" "$LIBDRM_DIR" | sed 's/^/  /'
ls -1 "$CJK_FONT" | sed 's/^/  /'
