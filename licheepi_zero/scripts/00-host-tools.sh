#!/bin/bash
# ---------------------------------------------------------------------------
# 00 主机工具链自检
#
# 工具链不再"解包 deb 到私有前缀"，而是要求**系统已经装好**（apt 一条命令）。
# 这个脚本只做三件事：
#   1. 确认是 root（rootfs 里要 chown，见 env.sh 的 need_root）
#   2. 逐个自检必需的命令 + 开发头文件，缺谁点名并给出安装命令
#   3. 准备 sunxi-tools/sunxi-fel（克隆 → 打 4 字节补丁 → 编译）
#
# 装工具链（Ubuntu/Debian，一次就够）：
#   apt-get install -y build-essential gcc make file bc bison flex git wget \
#     xz-utils bzip2 patch python3 python3-dev libpython3-dev python3-pil \
#     zlib1g-dev libssl-dev libfdt-dev libusb-1.0-0-dev pkg-config \
#     device-tree-compiler u-boot-tools mtd-utils proot qemu-user swig \
#     gcc-arm-linux-gnueabihf libc6-dev-armhf-cross linux-libc-dev-armhf-cross
# ---------------------------------------------------------------------------
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/env.sh"
script_init "$(basename "${BASH_SOURCE[0]}" .sh)"

# 必需命令：名字 | 说明（缺了会死在哪一步）
TOOLS=(
	"arm-linux-gnueabihf-gcc|交叉编译器（内核/U-Boot/LVGL demo）"
	"make|构建"
	"gcc|主机侧编译（sunxi-tools/pylibfdt）"
	"dtc|设备树编译"
	"mkimage|U-Boot 工具"
	"mkfs.ubifs|生成 UBIFS"
	"ubinize|生成 UBI 镜像"
	"proot|在 x86 上跑 arm rootfs 的 apk"
	"qemu-arm|同上（proot 的用户态模拟器）"
	"swig|U-Boot pylibfdt 绑定"
	"pkg-config|sunxi-tools 取 libusb/zlib 的 cflags"
	"python3|字体生成 + U-Boot 构建脚本"
	"bc|内核构建"
	"bison|内核/U-Boot 构建"
	"flex|内核/U-Boot 构建"
	"git|克隆 sunxi-tools"
	"wget|下载源码"
	"patch|打本地补丁"
	"file|校验产物类型"
)
# 必需的开发头文件（缺了要到链接期才炸，这里提前点名）
HEADERS=(
	"/usr/include/zlib.h|zlib1g-dev"
	"/usr/include/openssl/ssl.h|libssl-dev"
	"/usr/include/libusb-1.0/libusb.h|libusb-1.0-0-dev"
	"/usr/include/libfdt.h|libfdt-dev"
)

need_root "构建需要 root"

# ---------------------------------------------------------------------------
# 自检
# ---------------------------------------------------------------------------
log "00 自检主机工具链（root，uid=$(id -u)）"
missing=()
for spec in "${TOOLS[@]}"; do
	name=${spec%%|*}; what=${spec#*|}
	if p=$(command -v "$name" 2>/dev/null); then
		printf '  \033[32m✓\033[0m %-26s %s\n' "$name" "$p"
	else
		printf '  \033[31m✗\033[0m %-26s 缺失（%s）\n' "$name" "$what"
		missing+=("$name")
	fi
done

# python3 的头文件（U-Boot pylibfdt 要）
py_hdr=""
for h in /usr/include/python3*/Python.h; do
	[ -f "$h" ] && { py_hdr=$h; break; }
done
if [ -n "$py_hdr" ]; then
	printf '  \033[32m✓\033[0m %-26s %s\n' "Python.h" "$py_hdr"
else
	printf '  \033[31m✗\033[0m %-26s 缺失（python3-dev）\n' "Python.h"
	missing+=("python3-dev")
fi

for spec in "${HEADERS[@]}"; do
	hdr=${spec%%|*}; pkg=${spec#*|}
	if [ -f "$hdr" ]; then
		printf '  \033[32m✓\033[0m %-26s %s\n' "$(basename "$hdr")" "$hdr"
	else
		printf '  \033[31m✗\033[0m %-26s 缺失（%s）\n' "$(basename "$hdr")" "$pkg"
		missing+=("$pkg")
	fi
done

# Pillow：生成中文子集字体的必需品（07 会用）
if python3 -c "import PIL" 2>/dev/null; then
	printf '  \033[32m✓\033[0m %-26s %s\n' "Pillow" "$(python3 -c 'import PIL;print(PIL.__version__)')"
else
	printf '  \033[31m✗\033[0m %-26s 缺失（python3-pil）\n' "Pillow"
	missing+=("python3-pil")
fi

if [ "${#missing[@]}" -gt 0 ]; then
	warn "缺少 ${#missing[@]} 项：${missing[*]}"
	die "先装工具链再跑构建：
      apt-get update && apt-get install -y build-essential gcc make file bc bison flex \\
        git wget xz-utils bzip2 patch python3 python3-dev libpython3-dev python3-pil \\
        zlib1g-dev libssl-dev libfdt-dev libusb-1.0-0-dev pkg-config \\
        device-tree-compiler u-boot-tools mtd-utils proot qemu-user swig \\
        gcc-arm-linux-gnueabihf libc6-dev-armhf-cross linux-libc-dev-armhf-cross"
fi
log "  自检通过：${#TOOLS[@]} 个命令 + Python.h + 4 个头文件 + Pillow"

# ---------------------------------------------------------------------------
# sunxi-tools（sunxi-fel：FEL 烧录）
# ---------------------------------------------------------------------------
if [ ! -d "$SUNXI_TOOLS" ]; then
	log "克隆 sunxi-tools"
	git clone --depth 1 https://github.com/linux-sunxi/sunxi-tools.git "$SUNXI_TOOLS"
fi
# 上游 sunxi-fel 只发 3 字节地址（>16 MiB 静默回绕）。打 4 字节专用 opcode 补丁
# （0x13/0x12/0x21/0xDC，自带地址且不改芯片状态，BROM 复位后仍读得到偏移 0）。
# board/patches/sunxi-tools-4byte-spiflash.patch，幂等
if ! grep -q 'opcode_4b' "$SUNXI_TOOLS/fel-spiflash.c"; then
	log "  给 sunxi-tools 打 4 字节地址补丁（32 MiB flash 全片可烧）"
	( cd "$SUNXI_TOOLS" && patch -p1 < "$BOARD/patches/sunxi-tools-4byte-spiflash.patch" >/dev/null )
fi
# 需要重编：二进制不在，或补丁刚打上（源文件比二进制新）
need_fel_build() {
	[ -x "$SUNXI_TOOLS/sunxi-fel" ] || return 0
	[ "$SUNXI_TOOLS/sunxi-fel" -ot "$SUNXI_TOOLS/fel-spiflash.c" ] && return 0
	return 1
}
if need_fel_build; then
	log "编译 sunxi-tools/sunxi-fel"
	if ! ( cd "$SUNXI_TOOLS" && make -j"$(nproc)" sunxi-fel >"$LOGS/sunxi-tools.log" 2>&1 ); then
		tail -20 "$LOGS/sunxi-tools.log" >&2 2>/dev/null || true
		die "编译 sunxi-tools/sunxi-fel 失败（完整日志 $LOGS/sunxi-tools.log）"
	fi
fi
if "$SUNXI_TOOLS/sunxi-fel" --help >/dev/null 2>&1; then
	log "sunxi-fel OK: $SUNXI_TOOLS/sunxi-fel"
else
	die "sunxi-fel 编出来了但跑不起来：$SUNXI_TOOLS/sunxi-fel"
fi

log "00 完成"
