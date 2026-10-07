# LicheePi Zero Dock — 主线 U-Boot + 主线 Linux + Alpine（32 MiB SPI NOR）

Allwinner **V3s** / LicheePi Zero Dock，**32 MiB SPI NOR（MX25L25645G）** 上跑一整套主线系统：
U-Boot 2026.07 + Linux 7.2.7 + Alpine 3.24（**UBIFS on UBI**，可读写根），
4.3" 480x272 RGB 屏，外加一个 **LVGL 系统监控 demo**（DRM/KMS 直出 + 中文界面，开机自启）。

版本与 sha256 固定在 `scripts/env.sh` / `board/sources.lock`；分区数值只在 `board/layout.conf` 定义一处。

**已验证**：4 个分区 FEL 读回逐字节一致；从 NOR 独立启动；23.6 MiB UBIFS 根可读写；
屏幕 + LVGL 中文界面开机自启；SSH（镜像里建的普通用户，sudo 可用）；
32 MiB 全片寻址（16 MiB 以上 4 个 PEB 起点读到 `UBI#` magic）。

## 1. 快速开始

```bash
sudo ./build.sh            # 全流程 → out/ 下 4 个镜像 + lvgl-monitor
./flash.sh info            # 看 FEL 设备 / 分区规划 / 本地镜像
./flash.sh fel-boot        # 【推荐】先在内存里试启动，一个字节都不写 NOR
./flash.sh write-all       # 写 kernel + dtb + rootfs + u-boot（板子需在 FEL）
```

改内核/设备树后要重烧，就进 FEL 再 `write-images`（不动引导区）：
`./flash.sh force-fel` 让板子下次上电停在 FEL，或上电时把 SPI_MISO 接地。

**登录**：串口 / USB 串口 / LCD 控制台用 `root`（口令为空）；
SSH 用镜像里的普通用户（默认 `licheepi` / `licheepi`，见下面「使用者」一节）。

## 2. 分区（`board/layout.conf` 是唯一数据源）

```
0x000000  0x100000  u-boot   SPL@0 + U-Boot@0x8000 + 环境@0xF0000
0x100000  0x700000  kernel   zImage（裸镜像）
0x800000  0x010000  dtb      设备树
0x810000  0x17F0000 rootfs   UBI 卷 rootfs（UBIFS，23.64 MiB，可读写）
```

* 分区按 64 KiB 擦除块对齐（`06-manifest.sh` 检查）；U-Boot 与内核两份 dts 的分区表由脚本比对一致。
* 没有单独的 `u-boot-env` 分区（环境在 u-boot 分区尾部），也没有 `/data`（根本身可写）。
* **>16 MiB 怎么烧**：上游 `sunxi-fel` 只发 3 字节地址（越界静默回绕），本仓库给它打了
  **4 字节专用 opcode** 补丁（`0x13/0x12/0x21/0xDC`，不改芯片状态，BROM 永远读得到偏移 0）；
  U-Boot（`SPI_NOR_4B_OPCODES`）与内核用同一套。自检：`./flash.sh check-32m`。

## 3. 屏幕与 demo

显示初始化全在 Linux（U-Boot 不点屏）：`display-engine → mixer0 → tcon0 → panel-simple`
（`qiaodian,qd43003c0-40`），背光 PWM0/PB4。**触摸不可用**：NS2009 的 PENIRQ 没接到 SoC
（PB5 的网名是 `IO2`），实测 `/proc/interrupts` 里 tsc2007 计数恒为 0，而主线驱动必须有中断
才读坐标 —— 设备树里该节点是 `status = "disabled"`，所以 demo 纯显示、无输入。

LVGL demo 显示 **CPU 占用 / 频率 / 内存 / 磁盘 / 网络收发曲线** + 运行时长 / 负载 / 时间。
中文靠 `mkfont.py` 从 Noto Sans SC 抽出界面用到的汉字，生成 14/16/20px 4bpp 子集字体
挂成 Montserrat 的 fallback。已装进镜像并开机自启（OpenRC + `supervise-daemon`，
日志 `/var/log/lvgl-monitor.log`），启动时把 fbcon 从 tty1 解绑、停止时绑回来。

```bash
ssh <用户>@<板子IP> rc-service lvgl-monitor status      # stop 可让出屏幕回控制台
ssh <用户>@<板子IP> sudo vi /etc/conf.d/lvgl-monitor    # LVGL_MONITOR_ARGS="--detail" 等
```

改完 demo 想让板子用上新二进制，直接推上去并重启服务（二进制与 conf 都以仓库为准）：

```bash
scp out/lvgl-monitor <用户>@<板子IP>: && \
ssh <用户>@<板子IP> sudo sh -c 'install -m755 ~/lvgl-monitor /usr/local/bin/lvgl-monitor && \
  rc-service lvgl-monitor restart'
```

## 4. 构建

```bash
sudo ./build.sh [all|tools|sources|dts|uboot|kernel|rootfs|demo|manifest|clean|distclean]
```

**必须用 root**：rootfs 里所有文件要 `chown 0:0`、用户家目录再还原成对应 uid，
`mkfs.ubifs` 要读出正确属主。`./build.sh` 会在入口检查 uid 并打印装工具链的命令
（`clean` / `distclean` 不需要 root）。

### 使用者（镜像里的账号）

镜像里会创建一个属于 `wheel` 组（可 sudo）的普通用户，root 口令清空供控制台登录。
名字与口令都可以用环境变量覆盖，构建时生效：

```bash
IMG_USER=alice IMG_PASS=secret sudo -E ./build.sh rootfs
```

默认是 `licheepi` / `licheepi`（`IMG_UID`/`IMG_GID` 默认 1000）。

工具链用系统装的（Ubuntu / Debian 一次就够），`00` 步骤会逐个自检：

```bash
apt-get update && apt-get install -y \
  build-essential gcc make file bc bison flex git wget xz-utils bzip2 patch \
  python3 python3-dev libpython3-dev python3-pil \
  zlib1g-dev libssl-dev libfdt-dev libusb-1.0-0-dev pkg-config \
  device-tree-compiler u-boot-tools mtd-utils proot qemu-user swig \
  gcc-arm-linux-gnueabihf libc6-dev-armhf-cross linux-libc-dev-armhf-cross
```

* `pkg-config`（sunxi-tools 找 libusb）、`python3-pil`（生成字体）、`proot` + `qemu-user`
  （在 x86 上跑 arm 的 apk）都是必需品。
* **必须 x86_64**：交叉编译器和 qemu-user/proot 都只有 amd64 版，ARM 主机要 `--platform linux/amd64`。
* 内存紧就限并发：`MAKEFLAGS=-j4 ./build.sh`（默认 `-j$(nproc)`）。
* 可用 `WS=/path ./build.sh` 指定工作区，但 `board/` 必须和 `scripts/` 在同一个 `WS` 下。

实测（Ubuntu 26.04 容器 / x86_64 / 16 核 / root）：从零约 **10 分钟** —— 源码下载 ~5 min
（U-Boot 34 MB、内核 153 MB）、U-Boot 与内核各 ~1.5 min、rootfs+UBI ~4.3 min。
产物体积与 sha256 见 `out/MANIFEST.txt`（u-boot 409032 B / zImage 5492864 B / dtb 13821 B /
rootfs.ubi 8650752 B / lvgl-monitor 988800 B）。

构建根目录在 `build`（U-Boot/kbuild 不接受带空格的路径），`build/` 与 `out/` 的内容不入库。

## 5. 排错速查

| 现象 | 处理 |
|---|---|
| 进不了 FEL | ① `./flash.sh force-fel` 后复位；② TF 卡写 `fel-sdboot.sunxi`（`dd if=fel-sdboot.sunxi of=/dev/mmcblk0 bs=1024 seek=8`）；③ 上电时把 SPI_MISO 接地 |
| `sunxi-fel` 认不到设备 / `usb_bulk_send ERROR` | `1f3a:efe8` 既是 BROM 的 FEL，也是本板 g_serial gadget 的 VID/PID —— 板子跑着 Linux 时会连到 gadget。用 `lsusb` 看有无 "in FEL/flashing mode" 或看 `/dev/ttyACM*` 是否存在来判断 |
| 16 MiB 以上写坏 / 回绕 | 必须用本仓库编的 `sunxi-fel`（`./build.sh tools` 自动打补丁）；`./flash.sh check-32m` 自检 |
| 屏上有 console 但没有 `/dev/fb0` | `CONFIG_FB_DEVICE` 的默认值跟随 `CONFIG_FB`，裁掉 FB 就一起没了；片段里已显式 `CONFIG_FB_DEVICE=y` |
| demo 不显示、屏上还是 tty | fbcon 的 fbdev plane 挂在同一 CRTC 上且 zpos 更高，压住了 LVGL；已用 `lvgl-drm-hide-other-planes.patch` 摘掉。排查：`sudo grep -E "^(plane\|crtc)\|crtc=\|allocated by" /sys/kernel/debug/dri/0/state` |
| 重烧 rootfs 后 panic `unable to mount root fs on ubi0:rootfs` | 分区里还留着上一次的 UBI PEB，而 `ubinize -Q` 固定了 image sequence number → 新旧被当成同一镜像。`write-rootfs`/`write-images` 会自动采样并擦掉未覆盖区间（约 4 分钟） |
| `rc-status` 里看不到 `lvgl-monitor`（`rc-service status` 却是 started） | OpenRC 依赖缓存旧了：`sudo rc-update -u` |
| `apk add` 报证书不可信 / 时间不对 | 无 RTC：`swclock` 给镜像构建时间，`/etc/local.d/settime.start` 三层校时（NTP+IP → NTP+域名 → HTTP Date），日志 `logger -t settime`。急用 `sudo date -s '@<epoch>'` |
| 系统起不来 | `force-fel` 后 `./flash.sh write-images` 重烧内核/设备树（不动引导区）；整体重烧 `./flash.sh write-all` |

## 6. 目录

```
build.sh / flash.sh                  # 构建 / FEL 烧录·校验
board/                               # layout.conf（分区）、dtsi 模板、U-Boot/内核片段、补丁、sources.lock
scripts/                             # env.sh（公共变量）+ 00…07 各步骤脚本
demo/lvgl-monitor/                   # main.c / lv_conf.h / Makefile / mkfont.py
demo/lvgl-monitor/lvgl-monitor.conf  # 服务参数（镜像里 /etc/conf.d/lvgl-monitor 就是这份）
out/                                 # 产物（4 个镜像 + lvgl-monitor + MANIFEST.txt）
```

`build/` 是构建根目录（`src/` 源码、`logs/` 分步日志、`work/` 中间产物）；
`out/nor-backup/` 是 `./flash.sh backup` 整片备份的落点。
