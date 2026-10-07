#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# mkfont.py —— 从 TTF/OTF 里挑出"界面上真正用到的那几十个汉字"，
#              生成 LVGL 的 lv_font_fmt_txt 格式 C 文件（4bpp 抗锯齿）。
#
# 为什么不用 lv_font_conv：那是个 npm 包（要 Node.js）。这里用 Pillow(FreeType)
# 渲染 + 直接产出 LVGL 字体结构，宿主机只要有 python3-pil 就行。
#
# 生成格式的要点（对着 LVGL 自带的 lv_font_source_han_sans_sc_16_cjk.c 核对过）：
#   * 位图：4bpp、**连续比特流**（不是每行补到字节边界），MSB 先
#   * glyph_dsc[i] = {bitmap_index, adv_w, box_w, box_h, ofs_x, ofs_y}
#       adv_w = 步进(px) * 16            （LVGL 用 1/16 像素为单位）
#       box_w/box_h = 墨迹框大小
#       ofs_x = 墨迹框左边相对笔位置      ofs_y = -(墨迹框下边相对基线，向下为正)
#   * cmap：一个 SPARSE_TINY 段。注意 LVGL 的语义：
#       unicode_list 里放的是"相对 range_start 的偏移"（不是码点本身！），必须升序（二分查找）
#       range_length 是码点跨度（max-min+1），不是字形个数
#       glyph_id = glyph_id_start + 在 unicode_list 里的下标
#   * glyph id 0 保留为空字形
#
# 用法：
#   mkfont.py --font NotoSansSC-Regular.otf --size 20 --chars 系统监控 \
#             --name lv_font_cjk_20 --out lv_font_cjk_20.c
#   --chars 也可以用 @文件 的形式（构建脚本会把 main.c 里的汉字都抽出来）
# ---------------------------------------------------------------------------
import argparse
import sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    sys.exit("需要 Pillow：python3 -m pip install pillow（或装 python3-pil）")


def render(font, ch, size):
    """把字符画到画布上，返回 (墨迹框相对基线的坐标, 灰度像素列表)。"""
    canvas = Image.new("L", (size * 2, size * 2), 0)
    ImageDraw.Draw(canvas).text((size, size), ch, font=font, fill=255, anchor="ls")
    box = canvas.getbbox()
    if box is None:
        return None
    x0, y0, x1, y1 = box
    crop = canvas.crop(box)
    return (x0 - size, y0 - size, x1 - size, y1 - size), list(crop.tobytes())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--font", required=True, help="TTF/OTF 路径")
    ap.add_argument("--size", type=int, required=True, help="像素高度")
    ap.add_argument("--chars", required=True, help="字符集合，或 @文件名")
    ap.add_argument("--name", required=True, help="生成的 lv_font_t 变量名")
    ap.add_argument("--out", required=True)
    ap.add_argument("--bpp", type=int, default=4, choices=(1, 2, 4, 8))
    a = ap.parse_args()

    chars = open(a.chars[1:], encoding="utf-8").read() if a.chars.startswith("@") else a.chars
    # 拉丁字母/数字/符号交给 Montserrat（作为主字体），这里只做非 ASCII
    chars = sorted({c for c in chars if ord(c) > 0x7F and not c.isspace()})
    if not chars:
        sys.exit("字符集合为空")

    font = ImageFont.truetype(a.font, a.size)
    line_height = round(a.size * 20 / 16)          # 与 LVGL 内置 16px 字体同比例
    base_line = round(a.size * 5 / 16)

    bitmap = bytearray()
    glyphs = []
    missing = []
    nibbles = []                                   # 连续比特流的半字节序列
    for ch in chars:
        r = render(font, ch, a.size)
        if r is None:
            missing.append(ch)
            continue
        (bx0, by0, bx1, by1), pixels = r
        box_w, box_h = bx1 - bx0, by1 - by0
        adv = max(1, round(font.getlength(ch) * 16))
        gid = len(glyphs) + 1                      # 0 号保留
        bitmap_index = len(nibbles) // 2
        glyphs.append((bitmap_index, adv, box_w, box_h, bx0, -by1, ch))
        step = 256 // ((1 << a.bpp) - 1) if a.bpp < 8 else 1
        for v in pixels:
            nibbles.append(min((1 << a.bpp) - 1, v // step) if a.bpp < 8 else v)

    # 打包成连续比特流（MSB 先），末尾补 0 到整字节
    if a.bpp == 4:
        for i in range(0, len(nibbles), 2):
            hi = nibbles[i]
            lo = nibbles[i + 1] if i + 1 < len(nibbles) else 0
            bitmap.append((hi << 4) | lo)
    elif a.bpp == 8:
        bitmap.extend(nibbles)
    else:                                          # 1bpp / 2bpp
        acc = 0
        n = 0
        for v in nibbles:
            for k in range(a.bpp - 1, -1, -1):
                acc = (acc << 1) | ((v >> k) & 1)
                n += 1
                if n == 8:
                    bitmap.append(acc)
                    acc = 0
                    n = 0
        if n:
            bitmap.append(acc << (8 - n))

    if missing:
        print(f"  注意：字体里没有这些字符，已跳过：{''.join(missing)}", file=sys.stderr)

    def dump_bytes(data, per_line=16, indent="    "):
        out = []
        for i in range(0, len(data), per_line):
            out.append(indent + ",".join(f"0x{b:02x}" for b in data[i:i + per_line]) + ",")
        return "\n".join(out)

    with open(a.out, "w", encoding="utf-8") as f:
        f.write(f"""/* 由 demo/lvgl-monitor/mkfont.py 自动生成，请勿手改。
 * 源字体: {a.font}
 * 尺寸: {a.size}px  bpp: {a.bpp}  字符数: {len(glyphs)}
 * 字符: {''.join(g[6] for g in glyphs)}
 */
#include "lvgl.h"

#if LV_FONT_MONTSERRAT_14 || LV_FONT_MONTSERRAT_16 || LV_FONT_MONTSERRAT_20 || LV_FONT_MONTSERRAT_24

static const uint8_t glyph_bitmap[] = {{
{dump_bytes(bitmap)}
}};

static const lv_font_fmt_txt_glyph_dsc_t glyph_dsc[] = {{
    {{.bitmap_index = 0, .adv_w = 0, .box_w = 0, .box_h = 0, .ofs_x = 0, .ofs_y = 0}},  /* id 0 保留 */
""")
        for bi, adv, bw, bh, ox, oy, ch in glyphs:
            f.write(f"    {{.bitmap_index = {bi}, .adv_w = {adv}, .box_w = {bw}, "
                    f".box_h = {bh}, .ofs_x = {ox}, .ofs_y = {oy}}},  /* {ch} U+{ord(ch):04X} */\n")
        f.write("};\n\n")

        range_start = ord(glyphs[0][6])
        range_len = ord(glyphs[-1][6]) - range_start + 1
        f.write("/* unicode_list 是相对 range_start 的偏移（LVGL 的 SPARSE_* 就是这样用的）*/\n")
        f.write("static const uint16_t unicode_list_0[] = {\n")
        for i in range(0, len(glyphs), 12):
            f.write("    " + ",".join(f"0x{ord(g[6]) - range_start:04x}" for g in glyphs[i:i + 12]) + ",\n")
        f.write("};\n\n")

        f.write(f"""static const lv_font_fmt_txt_cmap_t cmaps[] = {{
    {{
        .range_start = 0x{range_start:04x}, .range_length = {range_len}, .glyph_id_start = 1,
        .unicode_list = unicode_list_0, .glyph_id_ofs_list = NULL, .list_length = {len(glyphs)},
        .type = LV_FONT_FMT_TXT_CMAP_SPARSE_TINY
    }}
}};

static const lv_font_fmt_txt_dsc_t font_dsc = {{
    .glyph_bitmap = glyph_bitmap,
    .glyph_dsc = glyph_dsc,
    .cmaps = cmaps,
    .kern_dsc = NULL,
    .kern_scale = 0,
    .cmap_num = 1,
    .bpp = {a.bpp},
    .kern_classes = 0,
    .bitmap_format = 0,
}};

const lv_font_t {a.name} = {{
    .get_glyph_dsc = lv_font_get_glyph_dsc_fmt_txt,
    .get_glyph_bitmap = lv_font_get_bitmap_fmt_txt,
    .line_height = {line_height},
    .base_line = {base_line},
    .subpx = LV_FONT_SUBPX_NONE,
    .underline_position = -2,
    .underline_thickness = 1,
    .static_bitmap = 1,
    .dsc = &font_dsc,
    .fallback = NULL,
    .user_data = NULL,
}};

#endif /* 主字体开关 */
""")
    print(f"  {a.out}: {len(glyphs)} 字形, 位图 {len(bitmap)} 字节")


if __name__ == "__main__":
    main()
