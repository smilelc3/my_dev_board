/**
 * lv_conf.h —— lvgl-monitor 专用配置（LVGL v9.6）
 *
 * LVGL 的 lv_conf_internal.h 会给所有没在这里出现的选项填默认值，
 * 所以这里只写"和默认不同"的部分，改起来一目了然。
 */
#ifndef LV_CONF_H
#define LV_CONF_H

#include <stdint.h>

/* ------------------------------------------------------------------ */
/* 基础                                                                */
/* ------------------------------------------------------------------ */
/* LVGL 9.6 起用 LV_COLOR_FORMAT_DEFAULT（LV_COLOR_DEPTH 已废弃，会刷一堆 #warning）；
 * 面板/DRM dumb buffer 都是 32bpp XRGB8888 */
#define LV_COLOR_FORMAT_DEFAULT LV_COLOR_FORMAT_XRGB8888
#define LV_USE_OS               LV_OS_NONE  /* 裸机式主循环，不依赖线程库   */
#define LV_DEF_REFR_PERIOD      33
#define LV_DPI_DEF              130

/* 直接吃 libc 的 malloc：LVGL 内部堆 64KB 对 480x272 的双缓冲不够用 */
#define LV_USE_STDLIB_MALLOC    LV_STDLIB_CLIB
#define LV_USE_STDLIB_STRING    LV_STDLIB_CLIB
#define LV_USE_STDLIB_SPRINTF   LV_STDLIB_CLIB

/* ------------------------------------------------------------------ */
/* 显示：Linux DRM/KMS（/dev/dri/card0，dumb buffer，不需要 GPU/GBM/EGL） */
/* ------------------------------------------------------------------ */
#define LV_USE_LINUX_DRM                1
#define LV_LINUX_DRM_AUTO_BACKEND       0                       /* 不靠 LV_USE_OPENGLES 猜 */
#define LV_LINUX_DRM_BACKEND            LV_LINUX_DRM_BACKEND_FBDEV

/* 保留 fbdev 后端只是为了对照调试（--fbdev），默认不用 */
#define LV_USE_LINUX_FBDEV              1
#define LV_LINUX_FBDEV_RENDER_MODE      LV_DISPLAY_RENDER_MODE_PARTIAL
#define LV_LINUX_FBDEV_BUFFER_COUNT     2
#define LV_LINUX_FBDEV_BUFFER_SIZE      60
#define LV_LINUX_FBDEV_MMAP             1
#define LV_LINUX_FBDEV_VSYNC            0

/* ------------------------------------------------------------------ */
/* 输入：本 demo **纯显示，不注册任何输入设备**（main.c 里没有 lv_indev）  */
/*   * 本板触摸不可用：NS2009 的 PENIRQ 没接到 SoC，主线 tsc2007 必须有    */
/*     中断才读坐标，所以设备树里触摸节点是 status="disabled"（详见        */
/*     docs/details.md §5），板子上根本不会出现可用的触摸输入节点。        */
/*   * LV_USE_EVDEV 保留着只是为了以后外接 USB/I2C 输入设备时省一步；      */
/*     没有代码引用它，链接器会把它丢掉，不占体积。                       */
/* ------------------------------------------------------------------ */
#define LV_USE_EVDEV                    1

/* ------------------------------------------------------------------ */
/* 字体与主题（够用就好，字体是体积大头）                                 */
/* ------------------------------------------------------------------ */
#define LV_FONT_MONTSERRAT_14           1
#define LV_FONT_MONTSERRAT_16           1
#define LV_FONT_MONTSERRAT_20           1
#define LV_FONT_MONTSERRAT_24           1
#define LV_FONT_DEFAULT                 LV_FONT_DEFAULT_MONTSERRAT_14

#define LV_USE_THEME_DEFAULT            1
#define LV_THEME_DEFAULT_DARK           1

/* ------------------------------------------------------------------ */
/* 关掉用不到的大件，减小体积 / 编译时间                                  */
/* ------------------------------------------------------------------ */
#define LV_USE_THORVG                   0    /* 矢量图形（C++，不要） */
#define LV_USE_LOG                      0
#define LV_USE_ASSERT_NULL              1
#define LV_USE_ASSERT_MALLOC            1
#define LV_USE_SYSMON                   0    /* LVGL 自带的 sysmon 用不上，我们自己采样 */
#define LV_USE_PERF_MONITOR             0
#define LV_USE_MEM_MONITOR              0

#endif /* LV_CONF_H */
