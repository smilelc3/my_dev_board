#!/bin/bash
# ---------------------------------------------------------------------------
# 07 构建 LVGL 系统监控 demo（demo/lvgl-monitor）
#
#   * 静态链接 armv7：板子是 Alpine(musl)，主机工具链是 glibc 版，动态链接在板子上
#     找不到 ld-linux-armhf.so.3。
#   * 显示走 DRM/KMS（dumb buffer），只需要 libdrm 的 5 个核心文件（不用 meson）。
#   * 中文子集字体由 mkfont.py 从 Noto Sans SC 生成，挂成 Montserrat 的 fallback。
#
# 产出：out/lvgl-monitor（镜像里已装并开机自启；单独跑就 scp 上去）
# ---------------------------------------------------------------------------
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/env.sh"
script_init 07-lvgl-demo

SRCDIR="$WS/demo/lvgl-monitor"
BUILDDIR="$WORK/lvgl-demo"

[ -d "$LVGL_DIR" ] || die "缺少 LVGL 源码 $LVGL_DIR（先跑 ./build.sh sources）"
[ -d "$LIBDRM_DIR" ] || die "缺少 libdrm 源码 $LIBDRM_DIR（先跑 ./build.sh sources）"
[ -f "$CJK_FONT" ] || die "缺少中文字体 $CJK_FONT（先跑 ./build.sh sources）"
python3 -c "import PIL" 2>/dev/null || die "缺少 Pillow（生成中文子集字体用）：python3 -m pip install pillow 或 apt install python3-pil"

log "07 构建 LVGL $LVGL_VER 系统监控 demo"
rm -rf "$BUILDDIR"; mkdir -p "$BUILDDIR"
cp "$SRCDIR/main.c" "$SRCDIR/lv_conf.h" "$SRCDIR/Makefile" "$SRCDIR/mkfont.py" "$BUILDDIR/"

cd "$BUILDDIR"
log "  生成中文字体子集 + 编译 libdrm + LVGL（$(find "$LVGL_DIR/src" -name '*.c' | wc -l) 个源文件），静态链接"
make -j"$(nproc)" LVGL_DIR="$LVGL_DIR" LIBDRM_DIR="$LIBDRM_DIR" CJK_FONT="$CJK_FONT" >"$LOG" 2>&1
strip --strip-unneeded lvgl-monitor 2>/dev/null || \
	"${CROSS_COMPILE}strip" --strip-unneeded lvgl-monitor 2>/dev/null || true

[ -x lvgl-monitor ] || die "编译失败，看 $LOG"
file lvgl-monitor | grep -q "statically linked" || warn "产物不是静态链接，板子上可能跑不起来"
grep -q "lv_font_cjk_" "$LOG" || true
grep -q "ELF 32-bit LSB executable, ARM" <(file lvgl-monitor) || die "产物不是 ARM 可执行文件"

install -m755 lvgl-monitor "$OUT/lvgl-monitor"
log "07 完成：out/lvgl-monitor ($(size "$OUT/lvgl-monitor") bytes)"
echo "  推到板子上跑： scp out/lvgl-monitor 板子: && ssh 板子 sudo /usr/local/bin/lvgl-monitor"
echo "  （镜像里已经装好这个二进制，开机自启，一般不用手动跑）"
