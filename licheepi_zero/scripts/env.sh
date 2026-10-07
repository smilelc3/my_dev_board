#!/bin/bash
# ---------------------------------------------------------------------------
# 共享环境变量： source scripts/env.sh
#
#   WS  会话工作区（脚本/配置/产物，路径允许有空格）
#   B   构建根目录（**不能含空格**：U-Boot Makefile 与 kbuild 都会直接报错）
# ---------------------------------------------------------------------------

# 本文件是被 source 的，定位自己必须用 BASH_SOURCE[0]：被 source 时 $0 还是调用者的
# 路径，用 $0 会把 WS 解析错（demo/ 下的脚本就会挂）。
# 调用者可以预设 WS 覆盖工作区（WS=/work/x ./build.sh），不设就是本文件的上一级。
_WS_PRESET="${WS:-}"
export WS="${_WS_PRESET:-$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")}"
export B="$WS/build"

export SRC="$B/src"
export LOGS="$B/logs"
export WORK="$B/work"
export OUT="$WS/out"
export BOARD="$WS/board"

# ---- 镜像里的账号（可用环境变量覆盖，代码里不留具体值）----
#   IMG_USER  创建的用户名（属于 wheel 组，可 sudo），家目录 /home/$IMG_USER
#   IMG_PASS  该用户的口令
# 用户名不要带空格等特殊字符：家目录路径 /home/$IMG_USER 会用于还原属主。
export IMG_USER="${IMG_USER:-licheepi}"
export IMG_PASS="${IMG_PASS:-licheepi}"
export IMG_UID="${IMG_UID:-1000}"
export IMG_GID="${IMG_GID:-1000}"

# ---- 版本（可复现构建的锚点）----
export UBOOT_VER=2026.07
export KERNEL_VER=7.2.7
export ALPINE_VER=3.24.2
export LVGL_VER=9.6.0                                 # LVGL demo
export LIBDRM_VER=2.4.134                             # DRM 后端
export CJK_FONT_FILE=NotoSansSC-Regular.otf           # 中文字体源
export ALPINE_BRANCH=v3.24
export ALPINE_ARCH=armv7

export UBOOT_DIR="$SRC/u-boot-$UBOOT_VER"
export LINUX_DIR="$SRC/linux-$KERNEL_VER"
export SUNXI_TOOLS="$SRC/sunxi-tools"
export LVGL_DIR="$SRC/lvgl-$LVGL_VER"
export LIBDRM_DIR="$SRC/libdrm-$LIBDRM_VER"
export CJK_FONT="$SRC/$CJK_FONT_FILE"

# ---- 可复现：固定时间戳/用户名 ----
export SOURCE_DATE_EPOCH=1735689600                 # 2025-01-01 00:00:00 UTC
export KBUILD_BUILD_TIMESTAMP="2025-01-01 00:00:00 UTC"
export KBUILD_BUILD_USER=build
export KBUILD_BUILD_HOST=licheepi

# ---- 交叉工具链：一律用系统装的（见 README「构建」一节），不设私有前缀 ----
# 只兜一下 swig 的库目录，有些发行版装在非默认位置
for _d in /usr/share/swig/* /usr/local/share/swig/*; do
	[ -f "$_d/swig.swg" ] && { export SWIG_LIB="$_d"; break; }
done
unset _d

export ARCH=arm
export CROSS_COMPILE=arm-linux-gnueabihf-
export LC_ALL=C

# ---- 分区/UBI 参数（board/layout.conf 是单一数据源）----
source "$BOARD/layout.conf"

# ---- 工具函数 ----
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
size() { stat -c%s "$1" 2>/dev/null || echo 0; }
hex()  { printf '0x%x' "$1"; }

# 各步骤脚本统一的开头：严格模式 + 分步日志路径
#   script_init 03-uboot    ->  $LOG = build/logs/03-uboot.log
# 用函数而不是让每个脚本自己写 set/source/LOG，是为了只有一处定义、不会漏。
script_init() {
	set -euo pipefail
	LOG="$LOGS/$1.log"
}

# 构建要求 root：rootfs 要 chown 成 root（家目录再还原给用户），mkfs.ubifs 要读属主
need_root() {
	[ "$(id -u)" = 0 ] && return 0
	die "${1:-构建需要 root}（当前 uid=$(id -u)）
    用 root 跑：  sudo ./build.sh          # 或直接进 root shell
    工具链一次装好（Ubuntu/Debian）：
      apt-get install -y build-essential gcc make file bc bison flex git wget \\
        xz-utils bzip2 patch python3 python3-dev libpython3-dev python3-pil \\
        zlib1g-dev libssl-dev libfdt-dev libusb-1.0-0-dev pkg-config \\
        device-tree-compiler u-boot-tools mtd-utils proot qemu-user swig \\
        gcc-arm-linux-gnueabihf libc6-dev-armhf-cross linux-libc-dev-armhf-cross"
}

mkdir -p "$LOGS" "$WORK" "$OUT"
