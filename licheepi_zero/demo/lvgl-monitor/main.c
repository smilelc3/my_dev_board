/*
 * lvgl-monitor —— LicheePi Zero Dock (Allwinner V3s) 上的 LVGL 实时系统监控
 *
 * 显示：Linux **DRM/KMS**（/dev/dri/card0，dumb buffer 直出；不用 /dev/fb0、不用 GPU）
 * 输入：无（本板触摸不可用，见 README §5；程序是纯显示）
 * 中文：Noto Sans SC 子集（构建时由 mkfont.py 生成 14/16/20px 三个 4bpp 字体），
 *       作为 Montserrat 的 fallback —— 拉丁字母/数字仍走 Montserrat
 *
 *   CPU  使用率     ← /proc/stat 两次采样求差（user/nice/sys/irq/softirq/steal）
 *   CPU  频率       ← cpufreq sysfs，或直接从 CCU 时钟树读 "cpu" 时钟
 *                     （V3s 主线没有 cpufreq 驱动，见 README §6）
 *   内存 使用/剩余  ← /proc/meminfo（used = MemTotal - MemAvailable，free = MemFree）
 *   磁盘 使用/剩余  ← statvfs("/")（UBIFS on UBI）
 *   网络 收/发速率  ← /sys/class/net/<iface>/statistics/{rx,tx}_bytes，画成曲线
 *   其它           ← /proc/uptime、/proc/loadavg、系统时间
 *
 * 退出：Ctrl-C / kill
 *
 * 用法： ./lvgl-monitor [选项]
 *          -p, --period MS    刷新周期，默认 1000
 *          -d, --drm PATH     DRM 设备，默认 /dev/dri/card0
 *          -c, --connector N  DRM connector id，默认 -1（自动挑第一个已连接的）
 *              --fbdev        改用 /dev/fb0（对照用；默认走 DRM）
 *          -f, --fb PATH      配合 --fbdev
 *              --detail       启动就进详版
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <math.h>
#include <dirent.h>
#include <errno.h>
#include <sys/statvfs.h>

#include "lvgl.h"

/* 构建时由 mkfont.py 生成的中文子集字体 */
extern const lv_font_t lv_font_cjk_14;
extern const lv_font_t lv_font_cjk_16;
extern const lv_font_t lv_font_cjk_20;

/* ------------------------------------------------------------------ */
/* 全局状态                                                            */
/* ------------------------------------------------------------------ */
static lv_obj_t *bar_cpu, *bar_mem, *bar_disk;
static lv_obj_t *pct_cpu, *pct_mem, *pct_disk;
static lv_obj_t *det_cpu, *det_mem, *det_disk;
static lv_obj_t *lbl_footer, *lbl_freq, *lbl_net, *lbl_netpeak;
static lv_obj_t *chart;
static lv_chart_series_t *ser_rx, *ser_tx;

#define NET_POINTS 60                  /* 曲线点数（1 秒一个点 = 1 分钟） */
static int net_rx_hist[NET_POINTS], net_tx_hist[NET_POINTS];
static int net_hist_len = 0, net_hist_pos = 0;
static char net_iface[32] = "";

static bool  detail_mode = false;                  /* 简版 / 详版（--detail 启动即详版）*/
static int   period_ms   = 1000;
static volatile sig_atomic_t running = 1;

/* Montserrat 的副本 + 中文 fallback */
static lv_font_t font_14, font_16, font_20, font_24;

#define BAR_RANGE 1000                 /* 进度条千分比，0.1% 分辨率 */

/* ------------------------------------------------------------------ */
/* 采集：CPU（/proc/stat）                                             */
/* ------------------------------------------------------------------ */
struct cpu_sample {
	unsigned long long user, nice, sys, idle, iowait, irq, softirq, steal;
	unsigned long long total, busy;
};

static int cpu_read(struct cpu_sample *s)
{
	FILE *f = fopen("/proc/stat", "r");
	if (!f)
		return -1;
	int ok = fscanf(f, "cpu %llu %llu %llu %llu %llu %llu %llu %llu",
			&s->user, &s->nice, &s->sys, &s->idle, &s->iowait,
			&s->irq, &s->softirq, &s->steal);
	fclose(f);
	if (ok != 8)
		return -1;
	s->total = s->user + s->nice + s->sys + s->idle + s->iowait +
		   s->irq + s->softirq + s->steal;
	s->busy = s->total - s->idle - s->iowait;
	return 0;
}

/* ------------------------------------------------------------------ */
/* 采集：内存（/proc/meminfo，kB）                                      */
/* ------------------------------------------------------------------ */
struct mem_info {
	double total_mb, used_mb, free_mb, avail_mb, cached_mb, buffers_mb, shmem_mb;
};

static double meminfo_kb(const char *key)
{
	FILE *f = fopen("/proc/meminfo", "r");
	char line[256];
	double val = 0;
	if (!f)
		return 0;
	size_t klen = strlen(key);
	while (fgets(line, sizeof(line), f)) {
		if (strncmp(line, key, klen) == 0 && line[klen] == ':') {
			sscanf(line + klen + 1, "%lf", &val);
			break;
		}
	}
	fclose(f);
	return val;
}

static void mem_read(struct mem_info *m)
{
	double total = meminfo_kb("MemTotal");
	double avail = meminfo_kb("MemAvailable");
	m->total_mb   = total / 1024.0;
	m->avail_mb   = avail / 1024.0;
	m->free_mb    = meminfo_kb("MemFree") / 1024.0;
	m->used_mb    = (total - avail) / 1024.0;
	m->cached_mb  = meminfo_kb("Cached") / 1024.0;
	m->buffers_mb = meminfo_kb("Buffers") / 1024.0;
	m->shmem_mb   = meminfo_kb("Shmem") / 1024.0;
}

/* ------------------------------------------------------------------ */
/* 采集：磁盘（statvfs，根文件系统 UBIFS）                               */
/* ------------------------------------------------------------------ */
struct disk_info {
	double total_mb, used_mb, free_mb;
	double inode_used_pct;
};

static void disk_read(struct disk_info *d)
{
	struct statvfs vfs;
	if (statvfs("/", &vfs) != 0) {
		memset(d, 0, sizeof(*d));
		return;
	}
	double frs = (double)vfs.f_frsize;
	d->total_mb = (double)vfs.f_blocks * frs / 1048576.0;
	d->free_mb  = (double)vfs.f_bavail * frs / 1048576.0;
	d->used_mb  = ((double)vfs.f_blocks - (double)vfs.f_bfree) * frs / 1048576.0;
	d->inode_used_pct = vfs.f_files ?
		(100.0 * (double)(vfs.f_files - vfs.f_ffree) / (double)vfs.f_files) : 0.0;
}

/* ------------------------------------------------------------------ */
/* 采集：CPU 频率                                                      */
/*   V3s 在主线里没有 cpufreq 驱动（没有 OPP 表、也没有 pll-cpu 的        */
/*   notifier），所以顺序是：cpufreq sysfs（万一以后有了）→ CCU 时钟树。  */
/* ------------------------------------------------------------------ */
static int read_cpu_mhz(int *out_min, int *out_max)
{
	if (out_min) *out_min = 0;
	if (out_max) *out_max = 0;

	FILE *f = fopen("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq", "r");
	if (f) {                                  /* kHz */
		int khz = 0;
		if (fscanf(f, "%d", &khz) == 1 && khz > 0) {
			fclose(f);
			if (out_min) {
				FILE *g = fopen("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq", "r");
				if (g) { int v; if (fscanf(g, "%d", &v) == 1) *out_min = v / 1000; fclose(g); }
			}
			if (out_max) {
				FILE *g = fopen("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq", "r");
				if (g) { int v; if (fscanf(g, "%d", &v) == 1) *out_max = v / 1000; fclose(g); }
			}
			return khz / 1000;
		}
		fclose(f);
	}

	/* 从 /sys/kernel/debug/clk/clk_summary 里找名为 "cpu" 的时钟。
	 * 格式： 名字  enable_cnt prepare_cnt [protect_cnt] rate accuracy phase ...
	 * 列数在不同内核版本里会变，所以按"第一个 >= 1e6 的数就是 rate"来取值。 */
	f = fopen("/sys/kernel/debug/clk/clk_summary", "r");
	if (f) {
		char line[512];
		while (fgets(line, sizeof(line), f)) {
			char name[128];
			if (sscanf(line, " %127s", name) != 1 || strcmp(name, "cpu") != 0)
				continue;
			char *p = line + strlen(name);
			while (*p) {
				char *end = NULL;
				unsigned long long v = strtoull(p, &end, 10);
				if (end == p) { p++; continue; }
				if (v >= 1000000ULL) {         /* 单位 Hz */
					fclose(f);
					return (int)(v / 1000000ULL);
				}
				p = end;
			}
		}
		fclose(f);
	}
	return 0;                                      /* 0 = 读不到 */
}

/* ------------------------------------------------------------------ */
/* 采集：网络收发字节数                                                */
/* ------------------------------------------------------------------ */
static void net_detect_iface(void)
{
	DIR *d = opendir("/sys/class/net");
	if (!d)
		return;
	struct dirent *e;
	while ((e = readdir(d))) {
		if (e->d_name[0] == '.' || !strcmp(e->d_name, "lo"))
			continue;
		snprintf(net_iface, sizeof(net_iface), "%.31s", e->d_name);
		break;
	}
	closedir(d);
}

static void net_read_bytes(unsigned long long *rx, unsigned long long *tx)
{
	char path[160];
	*rx = *tx = 0;
	snprintf(path, sizeof(path), "/sys/class/net/%s/statistics/rx_bytes", net_iface);
	FILE *f = fopen(path, "r");
	if (f) { if (fscanf(f, "%llu", rx) != 1) *rx = 0; fclose(f); }
	snprintf(path, sizeof(path), "/sys/class/net/%s/statistics/tx_bytes", net_iface);
	f = fopen(path, "r");
	if (f) { if (fscanf(f, "%llu", tx) != 1) *tx = 0; fclose(f); }
}

/* 把字节速率格式化得好看点 */
static void fmt_rate(char *buf, size_t n, double bytes_per_s)
{
	if (bytes_per_s >= 1048576.0)
		snprintf(buf, n, "%.2f MB/s", bytes_per_s / 1048576.0);
	else if (bytes_per_s >= 1024.0)
		snprintf(buf, n, "%.1f KB/s", bytes_per_s / 1024.0);
	else
		snprintf(buf, n, "%.0f B/s", bytes_per_s);
}

/* ------------------------------------------------------------------ */
/* 小工具                                                              */
/* ------------------------------------------------------------------ */
static void fmt_uptime(char *buf, size_t n)
{
	FILE *f = fopen("/proc/uptime", "r");
	double up = 0;
	if (f) {
		if (fscanf(f, "%lf", &up) != 1)
			up = 0;
		fclose(f);
	}
	int sec = (int)up;
	int d = sec / 86400, h = (sec % 86400) / 3600, m = (sec % 3600) / 60;
	if (d)
		snprintf(buf, n, "%d天%d时%d分", d, h, m);
	else if (h)
		snprintf(buf, n, "%d时%d分", h, m);
	else
		snprintf(buf, n, "%d分%d秒", m, sec % 60);
}

static void fmt_load(char *buf, size_t n)
{
	FILE *f = fopen("/proc/loadavg", "r");
	float a = 0, b = 0, c = 0;
	if (f) {
		if (fscanf(f, "%f %f %f", &a, &b, &c) != 3)
			a = b = c = 0;
		fclose(f);
	}
	snprintf(buf, n, "负载 %.2f %.2f %.2f", a, b, c);
}

static lv_color_t load_color(int permille)
{
	if (permille >= 850)
		return lv_palette_main(LV_PALETTE_RED);
	if (permille >= 600)
		return lv_palette_main(LV_PALETTE_AMBER);
	return lv_palette_main(LV_PALETTE_GREEN);
}

static void bar_set(lv_obj_t *bar, int permille)
{
	if (permille < 0)
		permille = 0;
	if (permille > BAR_RANGE)
		permille = BAR_RANGE;
	lv_bar_set_value(bar, permille, LV_ANIM_OFF);
	lv_obj_set_style_bg_color(bar, load_color(permille), LV_PART_INDICATOR);
}


/* ------------------------------------------------------------------ */
/* 主刷新：每 period_ms 一次                                            */
/* ------------------------------------------------------------------ */
static void monitor_timer_cb(lv_timer_t *t)
{
	(void)t;
	static bool first = true;
	static struct cpu_sample prev;
	static unsigned long long prev_rx = 0, prev_tx = 0;
	static double prev_t = 0;
	struct cpu_sample now;

	double now_t = (double)lv_tick_get() / 1000.0;

	/* ---- CPU 使用率 ---- */
	int cpu_permille = 0;
	double busy_pct = 0, usr = 0, sys = 0, iow = 0, idle = 0;
	if (cpu_read(&now) == 0) {
		if (!first) {
			unsigned long long dt = now.total - prev.total;
			unsigned long long db = now.busy - prev.busy;
			if (dt > 0) {
				busy_pct = 100.0 * (double)db / (double)dt;
				cpu_permille = (int)(1000.0 * (double)db / (double)dt);
				usr  = 100.0 * (double)((now.user + now.nice) - (prev.user + prev.nice)) / dt;
				sys  = 100.0 * (double)((now.sys + now.irq + now.softirq) -
							(prev.sys + prev.irq + prev.softirq)) / dt;
				iow  = 100.0 * (double)(now.iowait - prev.iowait) / dt;
				idle = 100.0 * (double)(now.idle - prev.idle) / dt;
			}
		}
		prev = now;
		first = false;
	}
	bar_set(bar_cpu, cpu_permille);
	lv_label_set_text_fmt(pct_cpu, "%d%%", (cpu_permille + 5) / 10);

	/* ---- CPU 频率 ---- */
	int fmin = 0, fmax = 0;
	int mhz = read_cpu_mhz(&fmin, &fmax);
	if (mhz > 0)
		lv_label_set_text_fmt(lbl_freq, "%dMHz", mhz);
	else
		lv_label_set_text(lbl_freq, "频率 --");

	/* ---- 内存 ---- */
	struct mem_info mi;
	mem_read(&mi);
	int mem_permille = mi.total_mb > 0 ? (int)(1000.0 * mi.used_mb / mi.total_mb) : 0;
	bar_set(bar_mem, mem_permille);
	lv_label_set_text_fmt(pct_mem, "%d%%", (mem_permille + 5) / 10);

	/* ---- 磁盘 ---- */
	struct disk_info di;
	disk_read(&di);
	int disk_permille = di.total_mb > 0 ? (int)(1000.0 * di.used_mb / di.total_mb) : 0;
	bar_set(bar_disk, disk_permille);
	lv_label_set_text_fmt(pct_disk, "%d%%", (disk_permille + 5) / 10);

	/* ---- 网络速率 ---- */
	double rx_rate = 0, tx_rate = 0;
	unsigned long long rx = 0, tx = 0;
	if (net_iface[0]) {
		net_read_bytes(&rx, &tx);
		if (prev_t > 0 && now_t > prev_t) {
			double dt = now_t - prev_t;
			rx_rate = (double)(rx - prev_rx) / dt;
			tx_rate = (double)(tx - prev_tx) / dt;
		}
		prev_rx = rx;
		prev_tx = tx;
		prev_t = now_t;
	}
	int rx_kb = (int)(rx_rate / 1024.0 + 0.5);
	int tx_kb = (int)(tx_rate / 1024.0 + 0.5);
	net_rx_hist[net_hist_pos] = rx_kb;
	net_tx_hist[net_hist_pos] = tx_kb;
	net_hist_pos = (net_hist_pos + 1) % NET_POINTS;
	if (net_hist_len < NET_POINTS)
		net_hist_len++;
	int peak = 1;
	for (int i = 0; i < net_hist_len; i++) {
		if (net_rx_hist[i] > peak) peak = net_rx_hist[i];
		if (net_tx_hist[i] > peak) peak = net_tx_hist[i];
	}
	/* 纵轴取"好看的"刻度：1/2/5 × 10^n */
	int axis = 1;
	{
		int scale = 1;
		while (peak / scale >= 10)
			scale *= 10;
		int lead = peak / scale;
		axis = (lead <= 1 ? 1 : lead <= 2 ? 2 : lead <= 5 ? 5 : 10) * scale;
		if (axis < 16)
			axis = 16;
	}
	lv_chart_set_axis_range(chart, LV_CHART_AXIS_PRIMARY_Y, 0, axis);
	lv_chart_set_next_value(chart, ser_rx, rx_kb);
	lv_chart_set_next_value(chart, ser_tx, tx_kb);

	char rr[32], tr[32];
	fmt_rate(rr, sizeof(rr), rx_rate);
	fmt_rate(tr, sizeof(tr), tx_rate);
	/* 左下角一行显示速率；右侧那行在简版显示峰值、详版显示累计（避免两段文字撞在一起）*/
	lv_label_set_text_fmt(lbl_net, "网络 %s   ↓ %s   ↑ %s", net_iface, rr, tr);
	if (detail_mode)
		lv_label_set_text_fmt(lbl_netpeak, "累计 ↓%.1f ↑%.1f MB",
				      (double)rx / 1048576.0, (double)tx / 1048576.0);
	else
		lv_label_set_text_fmt(lbl_netpeak, "峰值 %d KB/s", peak);

	/* ---- 三行明细 ---- */
	if (detail_mode) {
		lv_label_set_text_fmt(det_cpu, "用户 %.1f 内核 %.1f 等待 %.1f 空闲 %.1f%%   %dMHz",
				      usr, sys, iow, idle, mhz);
		lv_label_set_text_fmt(det_mem, "可用 %.1f  缓存 %.1f  缓冲 %.1f  共享 %.1f MB",
				      mi.avail_mb, mi.cached_mb, mi.buffers_mb, mi.shmem_mb);
		lv_label_set_text_fmt(det_disk, "已用 %.1f / %.1f  剩余 %.1f MB  索引 %.0f%%",
				      di.used_mb, di.total_mb, di.free_mb, di.inode_used_pct);
	} else {
		lv_label_set_text_fmt(det_cpu, "占用 %.1f%%   空闲 %.1f%%   %dMHz",
				      busy_pct, idle, mhz);
		lv_label_set_text_fmt(det_mem, "已用 %.1f / %.1f MB   剩余 %.1f MB",
				      mi.used_mb, mi.total_mb, mi.free_mb);
		lv_label_set_text_fmt(det_disk, "已用 %.1f / %.1f MB   剩余 %.1f MB",
				      di.used_mb, di.total_mb, di.free_mb);
	}

	/* ---- 页脚 ---- */
	char up[48], ld[64];
	fmt_uptime(up, sizeof(up));
	fmt_load(ld, sizeof(ld));
	time_t now_sec = time(NULL);
	struct tm tm;
	localtime_r(&now_sec, &tm);
	lv_label_set_text_fmt(lbl_footer, "运行 %s   %s   %02d:%02d:%02d",
			      up, ld, tm.tm_hour, tm.tm_min, tm.tm_sec);

}

/* ------------------------------------------------------------------ */
/* 界面                                                                */
/* ------------------------------------------------------------------ */
static void row_build(lv_obj_t *parent, int y, const char *name,
		      lv_obj_t **bar_out, lv_obj_t **pct_out, lv_obj_t **det_out)
{
	lv_obj_t *lbl = lv_label_create(parent);
	lv_label_set_text(lbl, name);
	lv_obj_set_style_text_font(lbl, &font_20, 0);
	lv_obj_set_style_text_color(lbl, lv_color_hex(0xdfe6ee), 0);
	lv_obj_align(lbl, LV_ALIGN_TOP_LEFT, 12, y);

	lv_obj_t *bar = lv_bar_create(parent);
	lv_obj_set_size(bar, 300, 14);
	lv_obj_align(bar, LV_ALIGN_TOP_LEFT, 80, y + 6);
	lv_bar_set_range(bar, 0, BAR_RANGE);
	lv_obj_set_style_radius(bar, 3, LV_PART_MAIN);
	lv_obj_set_style_radius(bar, 3, LV_PART_INDICATOR);
	lv_obj_set_style_bg_color(bar, lv_color_hex(0x2b3440), LV_PART_MAIN);

	lv_obj_t *pct = lv_label_create(parent);
	lv_obj_set_width(pct, 84);
	lv_obj_set_style_text_align(pct, LV_TEXT_ALIGN_RIGHT, 0);
	lv_obj_set_style_text_font(pct, &font_20, 0);
	lv_obj_set_style_text_color(pct, lv_color_white(), 0);
	lv_obj_align(pct, LV_ALIGN_TOP_RIGHT, -10, y - 1);
	lv_label_set_text(pct, "--%");

	lv_obj_t *det = lv_label_create(parent);
	lv_obj_set_style_text_font(det, &font_14, 0);
	lv_obj_set_style_text_color(det, lv_color_hex(0x8fa3b8), 0);
	lv_obj_align(det, LV_ALIGN_TOP_LEFT, 12, y + 26);
	lv_label_set_text(det, "...");

	*bar_out = bar;
	*pct_out = pct;
	*det_out = det;
}

static void ui_build(void)
{
	lv_obj_t *scr = lv_screen_active();
	lv_obj_set_style_bg_color(scr, lv_color_hex(0x101720), 0);
	lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, 0);

	/* ---- 标题栏（左上标题，右上 CPU 频率）---- */
	lv_obj_t *hdr = lv_obj_create(scr);
	lv_obj_set_size(hdr, 480, 30);
	lv_obj_align(hdr, LV_ALIGN_TOP_LEFT, 0, 0);
	lv_obj_set_style_radius(hdr, 0, 0);
	lv_obj_set_style_border_width(hdr, 0, 0);
	lv_obj_set_style_bg_color(hdr, lv_color_hex(0x1b3a5c), 0);
	lv_obj_set_scrollable(hdr, false);

	lv_obj_t *title = lv_label_create(hdr);
	lv_label_set_text(title, "荔枝派 Zero (V3s) 系统监控");
	lv_obj_set_style_text_font(title, &font_16, 0);
	lv_obj_set_style_text_color(title, lv_color_white(), 0);
	lv_obj_align(title, LV_ALIGN_LEFT_MID, 8, 0);

	lbl_freq = lv_label_create(hdr);
	lv_obj_set_style_text_font(lbl_freq, &font_14, 0);
	lv_obj_set_style_text_color(lbl_freq, lv_color_hex(0xa8d8ff), 0);
	lv_obj_align(lbl_freq, LV_ALIGN_RIGHT_MID, -8, 0);
	lv_label_set_text(lbl_freq, "频率 --");

	/* ---- 三行：处理器 / 内存 / 磁盘 ---- */
	row_build(scr,  34, "处理器", &bar_cpu,  &pct_cpu,  &det_cpu);
	row_build(scr,  80, "内存",   &bar_mem,  &pct_mem,  &det_mem);
	row_build(scr, 126, "磁盘",   &bar_disk, &pct_disk, &det_disk);

	/* ---- 网络速率 + 曲线 ---- */
	lbl_net = lv_label_create(scr);
	lv_obj_set_style_text_font(lbl_net, &font_14, 0);
	lv_obj_set_style_text_color(lbl_net, lv_color_hex(0xcfe0f0), 0);
	lv_obj_align(lbl_net, LV_ALIGN_TOP_LEFT, 12, 172);
	lv_label_set_text(lbl_net, "网络 ...");

	lbl_netpeak = lv_label_create(scr);
	lv_obj_set_style_text_font(lbl_netpeak, &font_14, 0);
	lv_obj_set_style_text_color(lbl_netpeak, lv_color_hex(0x6f8296), 0);
	lv_obj_align(lbl_netpeak, LV_ALIGN_TOP_RIGHT, -12, 172);
	lv_label_set_text(lbl_netpeak, "");

	chart = lv_chart_create(scr);
	lv_obj_set_size(chart, 464, 50);
	lv_obj_align(chart, LV_ALIGN_TOP_LEFT, 8, 192);
	lv_chart_set_type(chart, LV_CHART_TYPE_LINE);
	lv_chart_set_update_mode(chart, LV_CHART_UPDATE_MODE_SHIFT);
	lv_chart_set_point_count(chart, NET_POINTS);
	lv_chart_set_div_line_count(chart, 2, 4);
	lv_chart_set_axis_range(chart, LV_CHART_AXIS_PRIMARY_Y, 0, 64);
	lv_obj_set_style_bg_opa(chart, LV_OPA_TRANSP, LV_PART_MAIN);
	lv_obj_set_style_border_width(chart, 0, LV_PART_MAIN);
	lv_obj_set_style_pad_all(chart, 2, LV_PART_MAIN);
	lv_obj_set_style_line_width(chart, 1, LV_PART_MAIN);          /* 网格线细一点 */
	lv_obj_set_style_line_color(chart, lv_color_hex(0x263243), LV_PART_MAIN);
	lv_obj_set_style_size(chart, 0, 0, LV_PART_INDICATOR);        /* 不画数据点，只画线 */
	ser_rx = lv_chart_add_series(chart, lv_color_hex(0x35c6ff), LV_CHART_AXIS_PRIMARY_Y);
	ser_tx = lv_chart_add_series(chart, lv_color_hex(0xffb020), LV_CHART_AXIS_PRIMARY_Y);

	/* ---- 页脚 ---- */
	lbl_footer = lv_label_create(scr);
	lv_obj_set_style_text_font(lbl_footer, &font_14, 0);
	lv_obj_set_style_text_color(lbl_footer, lv_color_hex(0x9fb3c8), 0);
	lv_obj_align(lbl_footer, LV_ALIGN_BOTTOM_LEFT, 12, -6);
	lv_label_set_text(lbl_footer, "...");

}

/* ------------------------------------------------------------------ */
/* main                                                                */
/* ------------------------------------------------------------------ */
static void on_signal(int sig)
{
	(void)sig;
	running = 0;
}

static void fonts_init(void)
{
	/* 结构体浅拷贝再挂中文 fallback：Latin/数字仍是 Montserrat */
	font_14 = lv_font_montserrat_14; font_14.fallback = &lv_font_cjk_14;
	font_16 = lv_font_montserrat_16; font_16.fallback = &lv_font_cjk_16;
	font_20 = lv_font_montserrat_20; font_20.fallback = &lv_font_cjk_20;
	font_24 = lv_font_montserrat_24;            /* 只显示数字，不需要中文 */
}

static void usage(const char *argv0)
{
	printf("用法: %s [选项]\n"
	       "  -p, --period MS     刷新周期，默认 1000\n"
	       "  -d, --drm PATH      DRM 设备，默认 /dev/dri/card0\n"
	       "  -c, --connector N   DRM connector id，默认 -1（自动）\n"
	       "      --fbdev         改用 /dev/fb0（对照用；默认走 DRM）\n"
	       "  -f, --fb PATH       配合 --fbdev，默认 /dev/fb0\n"
	       "      --detail        启动就进详版（默认简版）\n"
	       "  -h, --help          显示本帮助\n", argv0);
}

int main(int argc, char **argv)
{
	const char *drm_path = "/dev/dri/card0", *fb_path = "/dev/fb0";
	int64_t connector_id = -1;
	bool use_fbdev = false, start_detail = false;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-p") || !strcmp(argv[i], "--period")) {
			if (++i < argc) period_ms = atoi(argv[i]);
		} else if (!strcmp(argv[i], "-d") || !strcmp(argv[i], "--drm")) {
			if (++i < argc) drm_path = argv[i];
		} else if (!strcmp(argv[i], "-c") || !strcmp(argv[i], "--connector")) {
			if (++i < argc) connector_id = atoll(argv[i]);
		} else if (!strcmp(argv[i], "--fbdev")) {
			use_fbdev = true;
		} else if (!strcmp(argv[i], "-f") || !strcmp(argv[i], "--fb")) {
			if (++i < argc) fb_path = argv[i];
		} else if (!strcmp(argv[i], "--detail")) {
			start_detail = true;
		} else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
			usage(argv[0]);
			return 0;
		} else {
			fprintf(stderr, "未知参数: %s\n", argv[i]);
			usage(argv[0]);
			return 2;
		}
	}
	if (period_ms < 200)
		period_ms = 200;

	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);

	lv_init();
	fonts_init();

	lv_display_t *disp;
	if (use_fbdev) {
		disp = lv_linux_fbdev_create();
		if (!disp || lv_linux_fbdev_set_file(disp, fb_path) != LV_RESULT_OK) {
			fprintf(stderr, "打不开 framebuffer %s\n", fb_path);
			return 1;
		}
	} else {
		disp = lv_linux_drm_create();
		if (!disp) {
			fprintf(stderr, "lv_linux_drm_create 失败\n");
			return 1;
		}
		if (lv_linux_drm_set_file(disp, drm_path, connector_id) != LV_RESULT_OK) {
			fprintf(stderr, "打不开 DRM 设备 %s（要 root 或在 video 组里；"
					"也可能是别的程序占着 DRM master）\n", drm_path);
			return 1;
		}
	}

	lv_theme_default_init(disp, lv_palette_main(LV_PALETTE_BLUE),
			      lv_palette_main(LV_PALETTE_GREEN), true, &font_14);

	net_detect_iface();
	ui_build();
	detail_mode = start_detail;
	monitor_timer_cb(NULL);

	lv_timer_t *tm = lv_timer_create(monitor_timer_cb, period_ms, NULL);
	lv_timer_ready(tm);

	printf("lvgl-monitor: %s=%s net=%s period=%dms  (Ctrl-C 退出)\n",
	       use_fbdev ? "fbdev" : "drm", use_fbdev ? fb_path : drm_path,
	       net_iface[0] ? net_iface : "(none)", period_ms);
	fflush(stdout);

	while (running) {
		uint32_t idle = lv_timer_handler();
		usleep((idle < 5 ? 5 : idle) * 1000);
	}

	printf("lvgl-monitor: 退出\n");
	return 0;
}
