#!/bin/bash
# ---------------------------------------------------------------------------
# 05 构建 Alpine Linux 根文件系统（可读写 UBIFS，装在 SPI NOR 的 UBI 卷上）
#
#  * 用官方 minirootfs，通过 qemu-arm + proot 在里面跑 apk（不用 chroot，但要 root）
#  * mkfs.ubifs + ubinize 生成可直接写到 NOR 的 UBI 镜像，属主 chown 成 root
#
# 产出：out/rootfs.ubi（要烧的镜像）、out/rootfs.ubifs（中间产物）
# ---------------------------------------------------------------------------
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/env.sh"
script_init 05-rootfs

ROOTFS="$WORK/rootfs"
TARBALL="$SRC/alpine-minirootfs-$ALPINE_VER-$ALPINE_ARCH.tar.gz"

PEBS=$(( ROOTFS_SIZE / UBI_PEB_SIZE ))                          # 分区内 PEB 数
LEBS=$(( PEBS - UBI_LAYOUT_PEBS - UBI_VOL_LEBS_RESERVED ))      # 卷的 LEB 数
VOL_SIZE=$(( LEBS * UBI_LEB_SIZE ))                             # 单位必须是 LEB 的整数倍
[ "$LEBS" -gt 20 ] || die "rootfs 分区太小（$LEBS LEBs）"

# proot + qemu 偶发 SIGABRT（本机 seccomp 加速不可用），失败重试几次
proot_run() {
	local i rc
	for i in 1 2 3; do
		PROOT_NO_SECCOMP=1 proot -q /usr/bin/qemu-arm -r "$ROOTFS" -0 -w /root \
			-b /proc -b /dev -b /sys -b /etc/resolv.conf \
			-b /lib64 -b /lib/x86_64-linux-gnu -b /usr/lib/x86_64-linux-gnu -b /etc/ld.so.cache \
			/bin/sh -c "$1" && return 0
		rc=$?
		warn "proot 第 $i 次失败（exit=$rc），重试…"
		sleep 1
	done
	return $rc
}

log "05 构建 Alpine $ALPINE_VER rootfs（分区 $PEBS PEB -> 卷 $LEBS LEBs = $((VOL_SIZE/1024/1024)) MiB）"
need_root "构建 rootfs 需要 root"
rm -rf "$ROOTFS"; mkdir -p "$ROOTFS"
tar -xzf "$TARBALL" -C "$ROOTFS"

# qemu-arm 要放进 rootfs 里给 proot 用（-q /usr/bin/qemu-arm），直接用系统的
QEMU_ARM=$(command -v qemu-arm || true)
[ -n "$QEMU_ARM" ] || die "找不到 qemu-arm（apt-get install -y qemu-user）"
log "  用 $QEMU_ARM 跑 arm 用户态（proot）"
cp "$QEMU_ARM" "$ROOTFS/usr/bin/qemu-arm"

log "  apk add alpine-base openrc openssh-server openssh-sftp-server sudo（必需）"
proot_run 'apk update && apk add --no-cache alpine-base openrc openssh-server openssh-sftp-server sudo' >>"$LOG" 2>&1
# 可选小工具（装不下就跳过）。mtd-utils 只装"只依赖 libc"的子包：
#   flash -> flash_erase   misc -> mtd_debug/mtdinfo
# 不要 mtd-utils-ubi（拖 libcrypto/lzo/zstd，镜像涨 1 MiB），要用进系统后 apk add。
proot_run 'apk add --no-cache evtest mtd-utils-flash mtd-utils-misc tzdata' >>"$LOG" 2>&1 || \
	warn "可选包安装失败（evtest/mtd-utils-flash/tzdata），继续"

log "  写板级配置（含时区 Asia/Shanghai / 东八区）"
# ---- 时区 Asia/Shanghai（UTC+8）----
# 没有 RTC，swclock 给镜像构建时间、联网后 ntpd 校成 UTC，时区只决定显示。
# 除 zoneinfo 外再写一份 /etc/TZ：musl 在 TZ 未设置时会读它，tzdata 没装上也不退回 UTC。
echo "Asia/Shanghai" > "$ROOTFS/etc/timezone"
mkdir -p "$ROOTFS/etc"
ln -sf /usr/share/zoneinfo/Asia/Shanghai "$ROOTFS/etc/localtime"
printf 'CST-8\n' > "$ROOTFS/etc/TZ"

echo "licheepi-zero" > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<'EOF'
127.0.0.1   localhost licheepi-zero
::1         localhost
EOF

# ---- fstab ----
# /tmp 必须写 size=：只有 51 MiB 内存，tmpfs 默认吃一半，放几个 MB 临时文件就 OOM。
cat > "$ROOTFS/etc/fstab" <<'EOF'
# <device>   <mount point>  <type>   <options>                 <dump> <pass>
# 根文件系统由内核直接挂载：ubi.mtd=rootfs root=ubi0:rootfs rootfstype=ubifs rw
tmpfs        /tmp           tmpfs    mode=1777,noatime,nosuid,size=8M  0  0
tmpfs        /run           tmpfs    mode=0755,noatime,nosuid,size=4M  0  0
tmpfs        /dev/shm       tmpfs    mode=1777,noatime,nosuid,size=4M  0  0
# debugfs：demo 从 clk_summary 读 CPU 频率（V3s 主线没有 cpufreq 驱动）
debugfs      /sys/kernel/debug  debugfs  noatime,nodev,noexec  0  0
EOF

# ---- inittab：LCD(tty1) / UART0(ttyS0) / USB gadget(ttyGS0) 三个控制台 ----
cat > "$ROOTFS/etc/inittab" <<'EOF'
# /etc/inittab  --  LicheePi Zero Dock

# 先挂 fstab 里的 tmpfs，再交给 OpenRC
::sysinit:/bin/mount -a

::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default

# 4.3" LCD（DRM fbcon）
tty1::respawn:/sbin/getty 38400 tty1
# UART0 调试串口 (PB8/PB9, 115200)
ttyS0::respawn:/sbin/getty -L 115200 ttyS0 vt100
# USB gadget 串口（OTG 口，主机侧 /dev/ttyACM0）
ttyGS0::respawn:/sbin/getty -L 115200 ttyGS0 vt100

::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
EOF

# ---- 网络：eth0 走 DHCP（Dock 板载 RJ45 / V3s 内置 PHY）----
cat > "$ROOTFS/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
	udhcpc_opts -t 5 -T 3 -b
EOF
printf 'nameserver 223.5.5.5\nnameserver 1.1.1.1\n' > "$ROOTFS/etc/resolv.conf"

# ---- 板上的小工具 ----
mkdir -p "$ROOTFS/usr/local/sbin"
cat > "$ROOTFS/usr/local/sbin/force-fel" <<'EOF'
#!/bin/sh
# 擦掉 NOR 前 64 KiB 引导镜像：下次上电 BROM 找不到 eGON，停在 FEL 可重烧
set -e
echo "把 /dev/mtdblock0 前 64 KiB 清零 ..."
dd if=/dev/zero of=/dev/mtdblock0 bs=1024 count=64 conv=notrunc
sync
echo "完成。reboot 之后板子会停在 FEL 模式 (USB 1f3a:efe8)。"
EOF

cat > "$ROOTFS/usr/local/sbin/lp-info" <<'EOF'
#!/bin/sh
echo "== 系统 =="
cat /etc/alpine-release; uname -a
echo; echo "== MTD 分区 =="; cat /proc/mtd
echo; echo "== UBI 卷 =="; ubinfo -a 2>/dev/null || echo "(无)"
echo; echo "== 挂载 =="; mount | grep -v -E 'cgroup|debugfs'
echo; echo "== 显示/触摸 =="
ls -l /dev/fb0 /dev/dri/card0 /dev/input/event* 2>/dev/null
echo; echo "== 网络 =="; ip -4 addr show 2>/dev/null
EOF
chmod 755 "$ROOTFS/usr/local/sbin/force-fel" "$ROOTFS/usr/local/sbin/lp-info"

# ---- LVGL 监控：装进镜像 + 开机自启（demo 步骤在 rootfs 之前，二进制一定在）----
[ -f "$OUT/lvgl-monitor" ] || die "缺少 out/lvgl-monitor：先跑 ./build.sh demo"
install -m755 "$OUT/lvgl-monitor" "$ROOTFS/usr/local/bin/lvgl-monitor"
# conf 的单一来源在仓库里，--push 也用同一份，避免两边写法漂移
install -m644 "$WS/demo/lvgl-monitor/lvgl-monitor.conf" "$ROOTFS/etc/conf.d/lvgl-monitor"

cat > "$ROOTFS/etc/init.d/lvgl-monitor" <<'INITEOF'
#!/sbin/openrc-run
# LicheePi Zero Dock 的 LVGL 系统监控（DRM/KMS 直出，480x272）
# 和 fbcon 抢屏：启动前把它从 tty1 解绑，停止时绑回。
# 想让回控制台：rc-service lvgl-monitor stop；参数在 /etc/conf.d/lvgl-monitor

description="LVGL system monitor (DRM/KMS + Chinese UI)"
command="/usr/local/bin/lvgl-monitor"
command_args="${LVGL_MONITOR_ARGS:-}"
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0
output_log="/var/log/lvgl-monitor.log"
error_log="/var/log/lvgl-monitor.log"
pidfile="/run/lvgl-monitor.pid"

VTCON="/sys/class/vtconsole/vtcon1/bind"

depend() {
	need localmount
	after local
	use net
}

start_pre() {
	# 屏幕让给监控界面（程序自己还会把 CRTC 上别的 plane 摘掉）
	[ -w "$VTCON" ] && echo 0 > "$VTCON" 2>/dev/null
	return 0
}

stop_post() {
	# 交还控制台
	[ -w "$VTCON" ] && echo 1 > "$VTCON" 2>/dev/null
	return 0
}
INITEOF
chmod 755 "$ROOTFS/etc/init.d/lvgl-monitor"

# ---- 时间：没有 RTC，开机时钟停在 1970 会让 apk 的 TLS 校验失败 ----
# swclock 用这个文件的 mtime 设系统时间（= 镜像构建时间），之后 ntpd 联网校时。
touch -d "@$SOURCE_DATE_EPOCH" "$ROOTFS/var/lib/misc/openrc-shutdowntime"
# ntpd 的 peer：先用 IPv4 字面量（有些网络会把域名解析劫持成 fake-IP，UDP/123 就出不去），
# 再补域名，常规环境两者皆可
printf 'NTPD_OPTS="-N -p 203.107.6.88 -p ntp.aliyun.com"\n' > "$ROOTFS/etc/conf.d/ntpd"

# 开机一次性校时（三层兜底）：时间不对会让 apk/HTTPS 报"证书未生效"
mkdir -p "$ROOTFS/etc/local.d"
cat > "$ROOTFS/etc/local.d/settime.start" <<'SETTIME'
#!/bin/sh
# 校时三层兜底：① NTP + IPv4 字面量（DNS 被劫持成 fake-IP 时只有这条能出去）
#              ② NTP + 域名     ③ HTTP Date（UDP/123 被挡时走 TCP）
# 两个坑：整段必须放后台（同步等 NTP 会把 default runlevel 卡在 starting）；
#         HTTP 拿到的 GMT 要按 UTC 解释（date -s @epoch），否则差一个时区。
(
	sleep 3
	for s in 203.107.6.88 ntp.aliyun.com ntp1.aliyun.com; do
		timeout 12 ntpd -q -n -p "$s" >/dev/null 2>&1 && {
			logger -t settime "NTP 校时成功 peer=$s now=$(date -u '+%F %T UTC')"
			exit 0
		}
	done
	for u in https://mirrors.aliyun.com/ http://mirrors.aliyun.com/ https://www.baidu.com/; do
		d=$(wget -qS --spider --timeout=6 "$u" 2>&1 | sed -n 's/^ *[Dd]ate: //p' | head -1)
		[ -n "$d" ] || continue
		e=$(date -u -D '%a, %d %b %Y %H:%M:%S GMT' -d "$d" +%s 2>/dev/null)
		if [ -n "$e" ] && date -s "@$e" >/dev/null 2>&1; then
			logger -t settime "HTTP Date 校时成功 $u now=$(date -u '+%F %T UTC')"
			exit 0
		fi
	done
	logger -t settime "校时失败：NTP 与 HTTP Date 都不可用（时间不准会让 apk 报证书错误）"
) &
exit 0
SETTIME
chmod 755 "$ROOTFS/etc/local.d/settime.start"

# ---- SSH：openssh sshd + 主机密钥 ----
cat >> "$ROOTFS/etc/ssh/sshd_config" <<'EOF'

# ---- LicheePi Zero Dock ----
PermitRootLogin no
PasswordAuthentication yes
EOF

# ---- 用户与口令 ----
#   root 口令清空（控制台免密码登录）；新建用户 $IMG_USER，加入 wheel 组并允许 sudo
cat > "$ROOTFS/etc/sudoers.d/wheel" <<'EOF'
%wheel ALL=(ALL) ALL
EOF
chmod 440 "$ROOTFS/etc/sudoers.d/wheel"

# ---- motd ----
cat > "$ROOTFS/etc/motd" <<EOF

  Alpine Linux $ALPINE_VER   ·   licheepi-zero

EOF

log "  OpenRC 服务与 root 口令"
proot_run '
set -e
for s in devfs dmesg mdev hwdrivers modules; do rc-update add $s sysinit >/dev/null 2>&1 || true; done
for s in sysctl hostname bootmisc syslog networking; do rc-update add $s boot >/dev/null 2>&1 || true; done
for s in killprocs mount-ro savecache; do rc-update add $s shutdown >/dev/null 2>&1 || true; done
rc-update add local default >/dev/null 2>&1 || true
rc-update add lvgl-monitor default >/dev/null 2>&1 || true
rc-update add sshd default >/dev/null 2>&1 || true
# 时钟：swclock 开机近似时间（镜像构建时间），ntpd 联网后校正
rc-update add swclock boot >/dev/null 2>&1 || true
rc-update add ntpd default >/dev/null 2>&1 || true

# root 口令清空（passwd -d 会把 shadow 里的口令字段置空）
passwd -d root

# 新用户（名字/口令/uid 来自 env.sh 的 IMG_USER / IMG_PASS / IMG_UID）
adduser -D -u $IMG_UID -s /bin/ash $IMG_USER 2>/dev/null || true
adduser $IMG_USER wheel 2>/dev/null || true
echo "$IMG_USER:$IMG_PASS" | chpasswd

# SSH 主机密钥
ssh-keygen -A >/dev/null 2>&1 || true
' >>"$LOG" 2>&1

log "  清理"
rm -f "$ROOTFS/usr/bin/qemu-arm"
rm -rf "$ROOTFS/var/cache/apk"/* "$ROOTFS/tmp"/* 2>/dev/null || true
mkdir -p "$ROOTFS/var/cache/apk" "$ROOTFS/tmp"
chmod 1777 "$ROOTFS/tmp"
echo "    根文件系统内容大小: $(du -sh "$ROOTFS" | cut -f1)"

# ---------------------------------------------------------------------------
# 生成 UBIFS + UBI 镜像
#   NOR: PEB=64KiB, min_io=1, subpage=1 -> LEB = 64KiB-128 = 65408
#   卷在镜像里就建成满大小（vol_size=$LEBS LEBs），不依赖内核 autoresize；
#   mkfs.ubifs -c 与卷大小一致，内核首次挂载时会把文件系统自动扩到整个卷。
# ---------------------------------------------------------------------------
log "  mkfs.ubifs -c $LEBS（root 直接 chown 成 root 属主）"
rm -f "$OUT/rootfs.ubifs" "$OUT/rootfs.ubi"
{
	set -e
	# 整个树归 root。因为是 root 在跑，这里是真的 chown（以前没有 root，
	# 要用 fakeroot 假装 —— 那套已经删掉了）。
	chown -R 0:0 "$ROOTFS"
	# 再恢复少数必须是非 root 的：/etc/shadow 归 shadow 组、
	# 用户家目录归用户自己（否则 ssh 进来写不了自己的家目录）
	chown 0:42 "$ROOTFS/etc/shadow" 2>/dev/null || true
	chown -R "$IMG_UID:$IMG_GID" "$ROOTFS/home/$IMG_USER" 2>/dev/null || true
	mkfs.ubifs -r "$ROOTFS" -m "$((UBI_MIN_IO))" -e "$((UBI_LEB_SIZE))" -c "$LEBS" \
	           -x zlib -o "$OUT/rootfs.ubifs"
} >>"$LOG" 2>&1

cat > "$WORK/ubinize.cfg" <<EOF
[ubifs]
mode=ubi
image=$OUT/rootfs.ubifs
vol_id=0
vol_type=dynamic
vol_name=$UBI_VOL_NAME
vol_size=$VOL_SIZE
vol_alignment=1
EOF

log "  ubinize -> out/rootfs.ubi"
ubinize -o "$OUT/rootfs.ubi" -m "$((UBI_MIN_IO))" -p "$((UBI_PEB_SIZE))" -Q 1280335921 \
	-s "$((UBI_SUB_PAGE))" "$WORK/ubinize.cfg" >>"$LOG" 2>&1

USZ=$(size "$OUT/rootfs.ubifs"); ISZ=$(size "$OUT/rootfs.ubi")
printf '    rootfs.ubifs: %8d bytes (%d KiB；卷 %d LEBs / %.2f MiB，首次挂载自动扩到满)\n' \
	"$USZ" "$((USZ/1024))" "$LEBS" "$(awk "BEGIN{printf \"%.2f\", $VOL_SIZE/1048576}")"
printf '    rootfs.ubi  : %8d bytes (%d KiB，写到 NOR 偏移 %s)\n' "$ISZ" "$((ISZ/1024))" "$(hex "$ROOTFS_OFF")"
[ "$ISZ" -le "$((ROOTFS_SIZE))" ] || die "UBI 镜像超出 rootfs 分区"
# 上游 sunxi-fel 只发 3 字节地址（>16 MiB 回绕）。本仓库打过 4 字节 opcode 补丁，
# 所以镜像上限就是 rootfs 分区；写到 16 MiB 以上时会提醒"必须用本仓库的 sunxi-fel"。
if [ "$ISZ" -gt "$((ROOTFS_SIZE))" ]; then
	die "UBI 镜像 $((ISZ/1024)) KiB 超过 rootfs 分区 $((ROOTFS_SIZE/1024)) KiB；
      请精简 rootfs 包（见 05-rootfs.sh）或调整 layout.conf"
fi
printf '    rootfs 分区 %d KiB，镜像占 %d KiB（余量 %d KiB）\n' \
	"$((ROOTFS_SIZE/1024))" "$((ISZ/1024))" "$(((ROOTFS_SIZE-ISZ)/1024))"
if [ $((ROOTFS_OFF + ISZ)) -gt $((0x1000000)) ]; then
	warn "镜像写到了 16 MiB 以上（0x$(printf %x $((ROOTFS_OFF + ISZ)))）：
      上游原版 sunxi-fel 会地址回绕，必须用本仓库 00-host-tools.sh 编出来的（已打 4 字节补丁）"
fi
log "05 完成：out/rootfs.ubi"
