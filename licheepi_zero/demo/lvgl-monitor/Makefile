# ---------------------------------------------------------------------------
# lvgl-monitor —— 交叉编译成静态 armv7 可执行文件
# 静态的原因：板子是 Alpine(musl)，主机工具链是 glibc 版，动态链接找不到解释器。
#
#   make -j$(nproc) LVGL_DIR=... LIBDRM_DIR=... CJK_FONT=...   # ./build.sh demo 会自动做
#
# 需要：LVGL 源码、libdrm 源码（只编核心）、中文字体（mkfont.py 生成子集）
# ---------------------------------------------------------------------------

# 依赖路径：正规用法是 ./build.sh demo 显式传进来（它从 scripts/env.sh 取版本号）。
# 下面只是单独 make 时的默认值，按"源码放在 $HOME/v3s/src 下"猜，可用变量覆盖：
#   make LVGL_DIR=/path/lvgl-9.6.0 LIBDRM_DIR=/path/libdrm-2.4.134 CJK_FONT=/path/font.otf
DEMO_SRC   ?= $(HOME)/v3s/src
LVGL_DIR   ?= $(DEMO_SRC)/lvgl-9.6.0
LIBDRM_DIR ?= $(DEMO_SRC)/libdrm-2.4.134
CJK_FONT   ?= $(DEMO_SRC)/NotoSansSC-Regular.otf
# 注意：make 自带 CC=cc 的默认值，用 ?= 是改不掉的，必须显式赋值
# （命令行 make CC=... 依然优先）
CROSS_COMPILE ?= arm-linux-gnueabihf-
CC := $(CROSS_COMPILE)gcc
AR := $(CROSS_COMPILE)ar
TARGET   ?= lvgl-monitor
BUILD    ?= build

# 默认目标必须是 all（文件里第一个规则是字体生成，会被当成默认目标）
.DEFAULT_GOAL := all

# 依赖检查：没有它的话，缺路径会表现为一堆莫名其妙的头文件找不到
define need_dir
	@[ -e "$(1)" ] || { echo "找不到 $(2)：$(1)"; \
	  echo "  用 ./build.sh demo 跑（会带上正确路径），或显式传 $(2)=/path"; exit 1; }
endef

# V3s = 单核 Cortex-A7（有 NEON/VFPv4），Alpine armv7 是硬浮点
ARCHFLAGS := -mcpu=cortex-a7 -mfpu=neon-vfpv4 -mfloat-abi=hard

CFLAGS  := $(ARCHFLAGS) -O2 -std=gnu11 -Wall -Wextra -Wno-unused-parameter \
           -ffunction-sections -fdata-sections -fno-common \
           -DLV_CONF_INCLUDE_SIMPLE -I. -I$(LVGL_DIR) \
           -I$(LIBDRM_DIR) -I$(LIBDRM_DIR)/include/drm \
           -MMD -MP
LDFLAGS := $(ARCHFLAGS) -static -Wl,--gc-sections -Wl,-O1
LDLIBS  := -lm -lpthread

# ---------------------------------------------------------------------------
# 1) 中文字体：抽 main.c 里的汉字各生成一套（14px 明细 / 16px 标题 / 20px 行名），
#    只做非 ASCII，拉丁仍走 Montserrat
# ---------------------------------------------------------------------------
CJK_14 := $(BUILD)/lv_font_cjk_14.c
CJK_16 := $(BUILD)/lv_font_cjk_16.c
CJK_20 := $(BUILD)/lv_font_cjk_20.c
CJK_CHARS := $(BUILD)/cjk_chars.txt
FONT_GEN_SRCS := main.c lv_conf.h mkfont.py

$(CJK_CHARS): $(FONT_GEN_SRCS) | $(BUILD)
	@python3 -c "import re,sys; s=open('main.c',encoding='utf-8').read(); \
c=sorted({ch for ch in s if ord(ch) > 0x7f and not ch.isspace()}); \
open('$@','w',encoding='utf-8').write(''.join(c)); print('  非 ASCII 字形 %d 个' % len(c))"

$(CJK_14): $(CJK_CHARS) mkfont.py | $(BUILD)
	@python3 mkfont.py --font $(CJK_FONT) --size 14 --chars @$(CJK_CHARS) --name lv_font_cjk_14 --out $@
$(CJK_16): $(CJK_CHARS) mkfont.py | $(BUILD)
	@python3 mkfont.py --font $(CJK_FONT) --size 16 --chars @$(CJK_CHARS) --name lv_font_cjk_16 --out $@
$(CJK_20): $(CJK_CHARS) mkfont.py | $(BUILD)
	@python3 mkfont.py --font $(CJK_FONT) --size 20 --chars @$(CJK_CHARS) --name lv_font_cjk_20 --out $@

# ---------------------------------------------------------------------------
# 2) libdrm 静态库：只用 5 个核心文件（不用 meson）；
#    xf86drm.c 需要的 generated_static_table_fourcc.h 由 libdrm 自带脚本现场生成
# ---------------------------------------------------------------------------
DRM_SRCS := xf86drm.c xf86drmMode.c xf86drmHash.c xf86drmRandom.c xf86drmSL.c
DRM_OBJS := $(addprefix $(BUILD)/libdrm_,$(addsuffix .o,$(basename $(DRM_SRCS))))
LIBDRM_A := $(BUILD)/libdrm.a
DRM_FOURCC_H := $(BUILD)/generated_static_table_fourcc.h

$(DRM_FOURCC_H): | $(BUILD)
	@python3 $(LIBDRM_DIR)/gen_table_fourcc.py $(LIBDRM_DIR)/include/drm/drm_fourcc.h $@

$(BUILD)/libdrm_%.o: $(LIBDRM_DIR)/%.c $(DRM_FOURCC_H) | $(BUILD)
	@echo "  CC      libdrm/$(notdir $<)"
	@$(CC) $(ARCHFLAGS) -O2 -fPIC -DMAJOR_IN_SYSMACROS \
	      -I$(LIBDRM_DIR) -I$(LIBDRM_DIR)/include/drm -I$(BUILD) \
	      -c $< -o $@

$(LIBDRM_A): $(DRM_OBJS)
	@echo "  AR      $@"
	@$(AR) rcs $@ $^

# ---------------------------------------------------------------------------
# 3) LVGL + demo：整棵 src 都编译，没开的模块是空文件，用不到的交给 --gc-sections
# ---------------------------------------------------------------------------
SRCS := main.c $(CJK_14) $(CJK_16) $(CJK_20) $(shell find $(LVGL_DIR)/src -type f -name '*.c')
OBJS := $(addprefix $(BUILD)/,$(addsuffix .o,$(subst /,_,$(SRCS))))

.PHONY: all clean size check-deps
all: check-deps $(TARGET)

check-deps:
	$(call need_dir,$(LVGL_DIR),LVGL_DIR)
	$(call need_dir,$(LIBDRM_DIR),LIBDRM_DIR)
	$(call need_dir,$(CJK_FONT),CJK_FONT)

$(TARGET): $(OBJS) $(LIBDRM_A)
	@echo "  LD      $@"
	@$(CC) $(LDFLAGS) -o $@ $(OBJS) $(LIBDRM_A) $(LDLIBS)
	@echo "  --> $@  $$(stat -c%s $@) bytes"

define SRC_RULE
$(BUILD)/$(subst /,_,$(1)).o: $(1) | $(BUILD)
	@mkdir -p $$(dir $$@)
	@echo "  CC      $$(notdir $$<)"
	@$$(CC) $$(CFLAGS) -c $$< -o $$@
endef
$(foreach s,$(SRCS),$(eval $(call SRC_RULE,$(s))))

$(BUILD):
	@mkdir -p $(BUILD)

size: $(TARGET)
	@size $(TARGET) 2>/dev/null || true
	@ls -l $(TARGET)

clean:
	rm -rf $(BUILD) $(TARGET)

-include $(OBJS:.o=.d)

