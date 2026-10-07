#!/bin/bash
# ===========================================================================
# 一步式构建：U-Boot + Linux + Alpine(UBIFS) -> out/ 下可直接烧录的 4 个镜像
#
#   sudo ./build.sh [all|tools|sources|dts|uboot|kernel|rootfs|demo|manifest|clean|distclean]
#
# 可以一次给多个步骤（./build.sh rootfs manifest）；分步日志在 build/logs/，产物在 out/。
# 除 clean/distclean 外都需要 root（rootfs 要 chown 成 root，见 README「构建」）。
# ===========================================================================
set -euo pipefail
HERE="$(dirname "$(readlink -f "$0")")"
source "$HERE/scripts/env.sh"

# 入口就检查 root，免得跑到一半才失败
case "${1:-all}" in
	clean|distclean|-h|--help|help) ;;                 # 这几个不需要 root
	*) need_root "构建需要 root" ;;
esac

ALL=(tools sources dts uboot kernel demo rootfs manifest)

# 步骤 -> {描述, 脚本名}。用 case 而不是 declare -A：macOS 自带的 bash 3.2 没有关联数组
# （构建本身只能在 Linux 上跑，但 help/参数检查不该挑平台）。
step_field() { # 步骤 描述|script
	local s=$1 f=$2
	case "$s" in
		tools)    [ "$f" = script ] && echo 00-host-tools || echo "00 自检主机工具链（系统装的）+ 编译 sunxi-fel" ;;
		sources)  [ "$f" = script ] && echo 01-sources    || echo "01 下载并校验 U-Boot / Linux / Alpine 源码" ;;
		dts)      [ "$f" = script ] && echo 02-dts        || echo "02 给 U-Boot 与 Linux 打设备树片段" ;;
		uboot)    [ "$f" = script ] && echo 03-uboot      || echo "03 编译 U-Boot" ;;
		kernel)   [ "$f" = script ] && echo 04-kernel     || echo "04 编译 Linux 内核 + 设备树" ;;
		rootfs)   [ "$f" = script ] && echo 05-rootfs     || echo "05 构建 Alpine rootfs + UBIFS/UBI 镜像" ;;
		manifest) [ "$f" = script ] && echo 06-manifest   || echo "06 生成产物清单" ;;
		demo)     [ "$f" = script ] && echo 07-lvgl-demo  || echo "07 构建 LVGL 系统监控 demo(静态 armv7 可执行文件)" ;;
		*) die "未知步骤：$s（可用：all tools sources dts uboot kernel rootfs demo manifest clean distclean）" ;;
	esac
}

run_step() {
	local s=$1
	log "──── $(step_field "$s" desc) ────"
	"$HERE/scripts/$(step_field "$s" script).sh"
}

start=$(date +%s)
STEPS=()
parse_steps() {
	local s
	for s in "$@"; do
		case "$s" in
			tools|sources|dts|uboot|kernel|rootfs|demo|manifest) STEPS+=("$s") ;;
			*) die "未知步骤：$s（可用：all tools sources dts uboot kernel rootfs demo manifest clean distclean）" ;;
		esac
	done
}
case "${1:-all}" in
	all)        STEPS=("${ALL[@]}") ;;
	tools|sources|dts|uboot|kernel|rootfs|demo|manifest) parse_steps "$@" ;;
	clean)
		log "清理构建中间产物"
		for d in "$UBOOT_DIR" "$LINUX_DIR"; do
			[ -d "$d" ] && ( cd "$d" && make distclean >/dev/null 2>&1 || true )
		done
		rm -rf "$WORK/rootfs" "$OUT"/*
		log "完成（源码保留：$SRC；工具链是系统装的，不受影响）"
		exit 0 ;;
	distclean)
		log "删除源码与构建目录"
		rm -rf "$B"
		exit 0 ;;
	-h|--help|help)
		# 打印文件头那段注释（与 flash.sh 的 usage 同一套写法，加行不用改行号）
		awk 'NR>1 { if (/^#/) { sub(/^# ?/, ""); print } else exit }' "$0"; exit 0 ;;
	*)  die "未知步骤：$1（可用：all tools sources dts uboot kernel rootfs demo manifest clean distclean）" ;;
esac

# 顺序约束：sources -> ... -> demo -> ... -> rootfs（demo 要 LVGL 源码，
# rootfs 里要装 demo 的二进制）。所以把步骤按 ALL 的顺序规整，再按需补齐前置步骤 ——
# 不能直接塞到最前面，否则 `./build.sh rootfs` 会变成 `demo rootfs` 而死在"缺少源码"。
has_step() { case " ${STEPS[*]:-} " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

if has_step rootfs && [ ! -f "$OUT/lvgl-monitor" ]; then
	log "out/lvgl-monitor 不在：按需补 sources/demo 并排在 rootfs 之前"
	FINAL=()
	placed() { case " ${FINAL[*]:-} " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
	for s in "${ALL[@]}"; do
		has_step "$s" || continue
		# demo 之前要有 sources；rootfs 之前要有 sources + demo
		if [ "$s" = demo ] || [ "$s" = rootfs ]; then
			placed sources || FINAL+=(sources)
		fi
		if [ "$s" = rootfs ]; then
			placed demo || FINAL+=(demo)
		fi
		FINAL+=("$s")
	done
	STEPS=("${FINAL[@]}")
fi

for s in "${STEPS[@]}"; do run_step "$s"; done

echo
log "构建完成，用时 $(( ($(date +%s) - start) / 60 )) 分 $(( ($(date +%s) - start) % 60 )) 秒"
echo
log "产物（out/）："
ls -la "$OUT" | sed 's/^/  /'
echo
log "下一步： ./flash.sh info   然后  ./flash.sh write-all  /  ./flash.sh fel-boot"
