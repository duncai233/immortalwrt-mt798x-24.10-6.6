#!/usr/bin/env bash
set -euo pipefail

BUILD="${BUILD:-/mnt/build_wrt/wrt}"
WORK="${WORK:-/root/codex_360t7_build}"
LOGDIR="$WORK/logs"
OUTDIR="$WORK/output-production"
JOBS="${JOBS:-$(nproc)}"
DATE="$(TZ=UTC-8 date +%y.%m.%d-%H.%M.%S)"
PATCH="$WORK/001-qihoo-360t7-production.patch"
OVERLAY="$WORK/MT7981-360T7.txt"
BG_IMAGE="${BG_IMAGE:-$WORK/bg1.jpg}"

mkdir -p "$LOGDIR" "$OUTDIR"
cd "$BUILD"

echo "== $(date -Is) production build for qihoo_360t7 =="
echo "cwd=$(pwd)"
echo "jobs=$JOBS"
echo "head=$(git rev-parse --short HEAD)"

git status --short > "$LOGDIR/status.before.production.$DATE.txt" || true

export FORCE_UNSAFE_CONFIGURE=1
export CCACHE_DIR="$BUILD/.ccache"

# Start from upstream source, then apply only the production 360T7 fixes.
git reset --hard HEAD
rm -f ./target/linux/mediatek/filogic/base-files/etc/uci-defaults/zz_qihoo_360t7-defaults

git apply --check "$PATCH"
git apply "$PATCH"

cp -f .config "$LOGDIR/config.before.production.$DATE" 2>/dev/null || true
rm -f .config .config.old

if [ ! -f ./defconfig/mt7981-ax3000.config ]; then
	echo "Missing upstream defconfig/mt7981-ax3000.config"
	exit 1
fi

FILTER='^(CONFIG_TARGET_mediatek(_.*)?=|CONFIG_TARGET_mediatek_filogic_DEVICE_|CONFIG_TARGET_DEVICE_|CONFIG_TARGET_MULTI_PROFILE=|CONFIG_TARGET_PER_DEVICE_ROOTFS=|CONFIG_HAS_SUBTARGETS=)'
grep -vE "$FILTER" ./defconfig/mt7981-ax3000.config > .config
cat "$OVERLAY" >> .config
cat >> .config <<'EOF_CONFIG'
CONFIG_PACKAGE_luci=y
CONFIG_LUCI_LANG_zh_Hans=y
CONFIG_PACKAGE_luci-theme-argon=y
CONFIG_PACKAGE_luci-app-argon-config=y
EOF_CONFIG

# Mirror the CI Settings.sh production adjustments.
[ ! -d ./package/base-files/files/etc/init.d ] || \
	find ./package/base-files/files/etc/init.d -type f -exec chmod 0755 {} +
for file in \
	./package/base-files/files/bin/config_generate \
	./package/base-files/files/bin/board_detect \
	./package/base-files/files/bin/ipcalc.sh \
	./package/network/config/netifd/files/sbin/ifup \
	./package/network/config/netifd/files/sbin/ifdown \
	./package/network/config/netifd/files/sbin/devstatus \
	./package/base-files/files/usr/libexec/login.sh \
	./package/base-files/files/etc/rc.common \
	./package/base-files/files/bin/busybox \
	./package/base-files/files/sbin/procd
do
	[ ! -e "$file" ] || chmod 0755 "$file"
done

CFG_FILE=./package/base-files/files/bin/config_generate
if [ -f "$CFG_FILE" ]; then
	sed -i "s/hostname='.*'/hostname='360T7'/g" "$CFG_FILE"
	grep -q "hostname='360T7'" "$CFG_FILE"
fi

ARGON_CONFIG=$({ find ./package ./feeds/luci -path '*/luci-app-argon-config/root/etc/config/argon' -type f 2>/dev/null || true; } | head -n 1)
if [ -z "$ARGON_CONFIG" ]; then
	echo "Missing luci-app-argon-config source; cannot apply required theme defaults."
	exit 1
fi
ARGON_STATIC=$({ find ./package ./feeds/luci -path '*/luci-theme-argon/htdocs/luci-static/argon' -type d 2>/dev/null || true; } | head -n 1)
if [ -z "$ARGON_STATIC" ]; then
	echo "Missing luci-theme-argon static directory; cannot install bg1.jpg."
	exit 1
fi
if [ ! -s "$BG_IMAGE" ]; then
	echo "Missing required Argon background image: $BG_IMAGE"
	exit 1
fi
BG_SHA=$(sha256sum "$BG_IMAGE" | awk '{print $1}')
ARGON_BG_DIR="$ARGON_STATIC/background"
install -d -m 0755 "$ARGON_BG_DIR"
install -m 0644 "$BG_IMAGE" "$ARGON_BG_DIR/bg1.jpg"
cmp -s "$BG_IMAGE" "$ARGON_BG_DIR/bg1.jpg"
sed -i \
	-e "s/option primary .*/option primary '#5aa79a'/" \
	-e "s/option dark_primary .*/option dark_primary '#5aa79a'/" \
	-e "s/option font_weight .*/option font_weight 'normal'/" \
	-e "s/option transparency .*/option transparency '0.5'/" \
	-e "s/option transparency_dark .*/option transparency_dark '0.5'/" \
	-e "s/option online_wallpaper .*/option online_wallpaper 'none'/" \
	"$ARGON_CONFIG"
grep -q "option primary '#5aa79a'" "$ARGON_CONFIG"
grep -q "option online_wallpaper 'none'" "$ARGON_CONFIG"
echo "argon_config=$ARGON_CONFIG"
echo "argon_background=$ARGON_BG_DIR/bg1.jpg sha256=$BG_SHA"

DTS_FILE=./target/linux/mediatek/dts/mt7981b-qihoo-360t7.dts
grep -q 'led-boot = &led_status_red;' "$DTS_FILE"
grep -q 'led-failsafe = &led_status_red;' "$DTS_FILE"
grep -q 'led-running = &led_status_green;' "$DTS_FILE"
grep -q 'led-upgrade = &led_status_green;' "$DTS_FILE"

if ! grep -q 'ucidef_set_interfaces_lan_wan "lan1 lan2 lan3" wan' \
	./target/linux/mediatek/filogic/base-files/etc/board.d/02_network; then
	echo "360T7 LAN/WAN layout is not standard lan1 lan2 lan3 + wan"
	exit 1
fi
if grep -q 'ucidef_set_interface_lan "lan1 lan2 lan3 wan"' \
	./target/linux/mediatek/filogic/base-files/etc/board.d/02_network; then
	echo "360T7 WAN is incorrectly bridged into LAN"
	exit 1
fi
awk '
	/qihoo,360t7\)/ { in_case = 1 }
	in_case && /192\.168\.1\.1/ { ok = 1 }
	in_case && /;;/ { in_case = 0 }
	END { exit(ok ? 0 : 1) }
' ./package/base-files/files/bin/config_generate || {
	echo "360T7 LAN default IP is not fixed to 192.168.1.1 in config_generate"
	exit 1
}

check_lan_dhcp_enabled() {
	local file="$1"

	awk '
		function clean(s) {
			gsub(/^'\''|'\''$/, "", s)
			gsub(/^"|"$/, "", s)
			return s
		}
		$1 == "config" && $2 == "dhcp" {
			section = clean($3)
			next
		}
		$1 == "config" {
			section = ""
		}
		section == "lan" && $1 == "option" && $2 == "interface" && clean($3) == "lan" { lan_interface = 1 }
		section == "lan" && $1 == "option" && $2 == "start" && clean($3) == "100" { lan_start = 1 }
		section == "lan" && $1 == "option" && $2 == "limit" && clean($3) == "150" { lan_limit = 1 }
		section == "lan" && $1 == "option" && $2 == "leasetime" && clean($3) == "12h" { lan_leasetime = 1 }
		section == "lan" && $1 == "option" && $2 == "ignore" && clean($3) == "1" { lan_ignored = 1 }
		section == "lan" && $1 == "option" && $2 == "dhcpv4" && clean($3) == "server" { lan_dhcpv4_server = 1 }
		section == "lan" && $1 == "option" && $2 == "dhcpv4" && clean($3) == "disabled" { lan_dhcpv4_disabled = 1 }
		section == "wan" && $1 == "option" && $2 == "ignore" && clean($3) == "1" { wan_ignored = 1 }
		END { exit((lan_interface && lan_start && lan_limit && lan_leasetime && lan_dhcpv4_server && !lan_dhcpv4_disabled && !lan_ignored && wan_ignored) ? 0 : 1) }
	' "$file"
}

check_lan_dhcp_enabled ./package/network/services/dnsmasq/files/dhcp.conf || {
	echo "Default dnsmasq DHCP config does not enable LAN DHCP and ignore WAN"
	exit 1
}

echo "== $(date -Is) make defconfig =="
make defconfig -j"$JOBS"
./scripts/diffconfig.sh > "$LOGDIR/diffconfig.production.$DATE.txt" || true
cp -f .config "$LOGDIR/config.production.$DATE"

echo "== $(date -Is) required production features =="
for symbol in \
	CONFIG_PACKAGE_luci-theme-argon \
	CONFIG_PACKAGE_luci-app-argon-config \
	CONFIG_PACKAGE_luci-app-turboacc-mtk \
	CONFIG_PACKAGE_luci-app-eqos-mtk \
	CONFIG_PACKAGE_kmod-mediatek_hnat \
	CONFIG_PACKAGE_kmod-warp \
	CONFIG_MTK_FAST_NAT_SUPPORT \
	CONFIG_MTK_WARP_V2
do
	grep -q "^${symbol}=y" .config || {
		echo "Missing required production config: ${symbol}=y"
		exit 1
	}
	grep "^${symbol}=y" .config
done | tee "$LOGDIR/features.production.$DATE.txt"

echo "== $(date -Is) clean stale target/rootfs artifacts =="
rm -rf ./bin/targets/mediatek/filogic
find ./staging_dir -maxdepth 2 -type d -name "root-*" -prune -exec rm -rf {} +
find ./staging_dir -path "*/stamp/.package_install*" -delete
find ./staging_dir -path "*/stamp/.target_*" -delete
find ./build_dir -maxdepth 2 -type d -name "root-*" -prune -exec rm -rf {} +

echo "== $(date -Is) make download =="
make download -j"$JOBS"

echo "== $(date -Is) make target/linux single-threaded =="
make -j1 V=s target/linux/compile

echo "== $(date -Is) make compile =="
make -j"$JOBS" || make -j1 V=s

echo "== $(date -Is) verify rootfs =="
ROOTFS_DIR=$(find ./staging_dir -maxdepth 2 -type d -name "root-*" | head -n 1)
if [ -z "$ROOTFS_DIR" ]; then
	echo "Cannot find target rootfs directory under staging_dir."
	exit 1
fi

fix_rootfs_permissions() {
	local root="$1"

	[ ! -d "$root/etc/init.d" ] || find "$root/etc/init.d" -type f -exec chmod 0755 {} +
	for dir in bin sbin usr/bin usr/sbin usr/libexec; do
		[ ! -d "$root/$dir" ] || find "$root/$dir" -maxdepth 1 -type f -exec chmod 0755 {} +
	done
	for dir in etc/board.d etc/uci-defaults etc/hotplug.d lib/preinit lib/netifd lib/wifi; do
		[ ! -d "$root/$dir" ] || find "$root/$dir" -type f -exec chmod 0755 {} +
	done
	[ ! -f "$root/usr/libexec/login.sh" ] || chmod 0755 "$root/usr/libexec/login.sh"
	[ ! -f "$root/etc/rc.common" ] || chmod 0755 "$root/etc/rc.common"
	[ ! -f "$root/bin/busybox" ] || chmod 0755 "$root/bin/busybox"
	[ ! -f "$root/sbin/procd" ] || chmod 0755 "$root/sbin/procd"
}

fix_rootfs_permissions "$ROOTFS_DIR"

check_mode() {
	local path="$1"
	local expected="$2"
	local mode

	if [ ! -e "$ROOTFS_DIR/$path" ]; then
		echo "Missing $path in $ROOTFS_DIR"
		exit 1
	fi

	mode=$(stat -c "%a" "$ROOTFS_DIR/$path")
	if [ "$mode" != "$expected" ]; then
		echo "Bad mode for $path: got $mode, expected $expected"
		exit 1
	fi
}

check_link() {
	local path="$1"
	local expected="$2"
	local target

	if [ ! -L "$ROOTFS_DIR/$path" ]; then
		echo "Missing symlink $path in $ROOTFS_DIR"
		exit 1
	fi

	target=$(readlink "$ROOTFS_DIR/$path")
	if [ "$target" != "$expected" ]; then
		echo "Bad symlink for $path: got $target, expected $expected"
		exit 1
	fi
}

check_file_sha256() {
	local path="$1"
	local expected="$2"
	local actual

	if [ ! -s "$path" ]; then
		echo "Missing or empty file: $path"
		exit 1
	fi

	actual=$(sha256sum "$path" | awk '{print $1}')
	if [ "$actual" != "$expected" ]; then
		echo "Bad sha256 for $path: got $actual, expected $expected"
		exit 1
	fi
	echo "$actual  $path"
}

for path in \
	bin/config_generate \
	bin/board_detect \
	bin/ipcalc.sh \
	sbin/ifup \
	sbin/ifdown \
	sbin/devstatus \
	sbin/wifi \
	sbin/mtwifi_cfg \
	lib/wifi/mtwifi.sh \
	lib/netifd/wireless/mtwifi.sh \
	etc/hotplug.d/net/10-mtwifi-detect \
	usr/libexec/login.sh \
	etc/init.d/network \
	etc/init.d/dnsmasq \
	etc/init.d/dropbear \
	etc/init.d/uhttpd \
	etc/init.d/firewall \
	etc/init.d/rpcd \
	etc/rc.common \
	bin/busybox \
	sbin/procd
do
	check_mode "$path" 755
	stat -c "%a %n" "$ROOTFS_DIR/$path"
done

if [ -e "$ROOTFS_DIR/sbin/l1util" ]; then
	check_mode sbin/l1util 755
	stat -c "%a %n" "$ROOTFS_DIR/sbin/l1util"
else
	echo "Optional sbin/l1util is not selected by the upstream 360T7 defconfig; skipping."
fi

awk '
	/qihoo,360t7\)/ { in_case = 1 }
	in_case && /ucidef_set_interfaces_lan_wan "lan1 lan2 lan3" wan/ { ok = 1 }
	in_case && /ucidef_set_interface_lan "lan1 lan2 lan3 wan"/ { bad = 1 }
	in_case && /;;/ { in_case = 0 }
	END { exit((ok && !bad) ? 0 : 1) }
' "$ROOTFS_DIR/etc/board.d/02_network" || {
	echo "360T7 board.d network layout is not standard lan1/lan2/lan3 LAN + wan WAN"
	exit 1
}

awk '
	/qihoo,360t7\)/ { in_case = 1 }
	in_case && /192\.168\.1\.1/ { ok = 1 }
	in_case && /;;/ { in_case = 0 }
	END { exit(ok ? 0 : 1) }
' "$ROOTFS_DIR/bin/config_generate" || {
	echo "360T7 LAN default IP is not fixed to 192.168.1.1 in rootfs config_generate"
	exit 1
}

grep -q "hostname='360T7'" "$ROOTFS_DIR/bin/config_generate" || {
	echo "Default hostname is not 360T7 in rootfs config_generate"
	exit 1
}

grep -q "set system.@system\\[0\\].hostname='360T7'" "$ROOTFS_DIR/etc/uci-defaults/zz_qihoo_360t7-defaults" || {
	echo "360T7 late uci-defaults does not set hostname"
	exit 1
}

grep -q "set dhcp.lan.dhcpv4='server'" "$ROOTFS_DIR/etc/uci-defaults/zz_qihoo_360t7-defaults" || {
	echo "360T7 late uci-defaults does not force LAN DHCPv4 server"
	exit 1
}

grep -q "modprobe mt_wifi" "$ROOTFS_DIR/etc/uci-defaults/zz_qihoo_360t7-defaults" || {
	echo "360T7 late uci-defaults does not load MTK WiFi for first-boot generation"
	exit 1
}

grep -q "/sbin/wifi config" "$ROOTFS_DIR/etc/uci-defaults/zz_qihoo_360t7-defaults" || {
	echo "360T7 late uci-defaults does not call upstream WiFi config generator"
	exit 1
}

grep -q "0.0.0.0:80" "$ROOTFS_DIR/etc/config/uhttpd" || {
	echo "uhttpd does not listen on 0.0.0.0:80"
	exit 1
}

grep -q "0.0.0.0:443" "$ROOTFS_DIR/etc/config/uhttpd" || {
	echo "uhttpd does not listen on 0.0.0.0:443"
	exit 1
}

check_lan_dhcp_enabled "$ROOTFS_DIR/etc/config/dhcp" || {
	echo "LAN DHCP defaults are not enabled, or WAN DHCP server is not ignored"
	exit 1
}

check_file_sha256 "$ROOTFS_DIR/www/luci-static/argon/background/bg1.jpg" "$BG_SHA"

grep -q "^mt_wifi" "$ROOTFS_DIR/etc/modules.d/mt_wifi" || {
	echo "mt_wifi is not configured for module autoload"
	exit 1
}

for path in \
	etc/wireless/l1profile.dat \
	etc/wireless/mediatek/mt7981.dbdc.b0.dat \
	etc/wireless/mediatek/mt7981.dbdc.b1.dat
do
	[ -s "$ROOTFS_DIR/$path" ] || {
		echo "Missing MTK WiFi profile data: $path"
		exit 1
	}
	ls -l "$ROOTFS_DIR/$path"
done

grep -q "option primary '#5aa79a'" "$ROOTFS_DIR/etc/config/argon" || {
	echo "Argon primary color was not applied"
	exit 1
}

grep -q "option online_wallpaper 'none'" "$ROOTFS_DIR/etc/config/argon" || {
	echo "Argon local wallpaper mode was not applied"
	exit 1
}

MANIFEST=$(find ./bin/targets -type f -name '*qihoo_360t7.manifest' | head -n 1)
if [ -z "$MANIFEST" ]; then
	MANIFEST=$(find ./bin/targets -type f -name '*.manifest' ! -path '*/packages/*' | head -n 1)
fi
if [ -z "$MANIFEST" ]; then
	echo "Missing firmware manifest"
	exit 1
fi

echo "manifest=$MANIFEST"
for pkg in \
	dnsmasq-full \
	dropbear \
	uhttpd \
	luci-theme-argon \
	luci-app-argon-config \
	kmod-mediatek_hnat \
	kmod-warp \
	luci-app-turboacc-mtk \
	luci-app-eqos-mtk \
	kmod-mt_wifi \
	mtwifi-cfg \
	wifi-scripts \
	wifi-dats \
	wpad-openssl \
	luci-app-mtwifi-cfg
do
	grep -q "^${pkg} " "$MANIFEST" || {
		echo "Missing package in manifest: $pkg"
		exit 1
	}
	grep "^${pkg} " "$MANIFEST"
done | tee "$LOGDIR/manifest.production.$DATE.txt"

echo "== $(date -Is) verify squashfs permissions =="
ROOTFS_IMG=$(find ./build_dir -path './build_dir/host*' -prune -o -type f -name 'root.squashfs' -print | head -n 1)
if [ -z "$ROOTFS_IMG" ]; then
	echo "Cannot find final root.squashfs under build_dir."
	exit 1
fi
SQUASHFS_CHECK="$WORK/squashfs-check-$DATE"
rm -rf "$SQUASHFS_CHECK"
unsquashfs -q -d "$SQUASHFS_CHECK" "$ROOTFS_IMG"
for path in \
	bin/config_generate \
	bin/board_detect \
	bin/ipcalc.sh \
	sbin/ifup \
	sbin/ifdown \
	sbin/devstatus \
	sbin/wifi \
	sbin/mtwifi_cfg \
	lib/wifi/mtwifi.sh \
	lib/netifd/wireless/mtwifi.sh \
	etc/hotplug.d/net/10-mtwifi-detect \
	usr/libexec/login.sh \
	etc/init.d/network \
	etc/init.d/dnsmasq \
	etc/init.d/dropbear \
	etc/init.d/uhttpd \
	etc/init.d/firewall \
	etc/init.d/rpcd
do
	mode=$(stat -c "%a" "$SQUASHFS_CHECK/$path")
	if [ "$mode" != "755" ]; then
		echo "Bad squashfs mode for $path: got $mode, expected 755"
		exit 1
	fi
	stat -c "%a %n" "$SQUASHFS_CHECK/$path"
done

if [ -e "$SQUASHFS_CHECK/sbin/l1util" ]; then
	mode=$(stat -c "%a" "$SQUASHFS_CHECK/sbin/l1util")
	if [ "$mode" != "755" ]; then
		echo "Bad squashfs mode for sbin/l1util: got $mode, expected 755"
		exit 1
	fi
	stat -c "%a %n" "$SQUASHFS_CHECK/sbin/l1util"
else
	echo "Optional squashfs sbin/l1util is not selected by the upstream 360T7 defconfig; skipping."
fi

check_squashfs_link() {
	local path="$1"
	local expected="$2"
	local target

	if [ ! -L "$SQUASHFS_CHECK/$path" ]; then
		echo "Missing squashfs symlink $path"
		exit 1
	fi

	target=$(readlink "$SQUASHFS_CHECK/$path")
	if [ "$target" != "$expected" ]; then
		echo "Bad squashfs symlink for $path: got $target, expected $expected"
		exit 1
	fi

	echo "$path -> $target"
}

check_squashfs_link etc/rc.d/S19dnsmasq ../init.d/dnsmasq
check_squashfs_link etc/rc.d/S19dropbear ../init.d/dropbear
check_squashfs_link etc/rc.d/S50uhttpd ../init.d/uhttpd

awk '
	/qihoo,360t7\)/ { in_case = 1 }
	in_case && /ucidef_set_interfaces_lan_wan "lan1 lan2 lan3" wan/ { ok = 1 }
	in_case && /ucidef_set_interface_lan "lan1 lan2 lan3 wan"/ { bad = 1 }
	in_case && /;;/ { in_case = 0 }
	END { exit((ok && !bad) ? 0 : 1) }
' "$SQUASHFS_CHECK/etc/board.d/02_network" || {
	echo "360T7 squashfs board.d network layout is not standard lan1/lan2/lan3 LAN + wan WAN"
	exit 1
}

awk '
	/qihoo,360t7\)/ { in_case = 1 }
	in_case && /192\.168\.1\.1/ { ok = 1 }
	in_case && /;;/ { in_case = 0 }
	END { exit(ok ? 0 : 1) }
' "$SQUASHFS_CHECK/bin/config_generate" || {
	echo "360T7 LAN default IP is not fixed to 192.168.1.1 in squashfs config_generate"
	exit 1
}

grep -q "hostname='360T7'" "$SQUASHFS_CHECK/bin/config_generate" || {
	echo "Default hostname is not 360T7 in squashfs config_generate"
	exit 1
}

grep -q "set system.@system\\[0\\].hostname='360T7'" "$SQUASHFS_CHECK/etc/uci-defaults/zz_qihoo_360t7-defaults" || {
	echo "360T7 late uci-defaults does not set hostname in squashfs"
	exit 1
}

grep -q "set dhcp.lan.dhcpv4='server'" "$SQUASHFS_CHECK/etc/uci-defaults/zz_qihoo_360t7-defaults" || {
	echo "360T7 late uci-defaults does not force LAN DHCPv4 server in squashfs"
	exit 1
}

grep -q "modprobe mt_wifi" "$SQUASHFS_CHECK/etc/uci-defaults/zz_qihoo_360t7-defaults" || {
	echo "360T7 late uci-defaults does not load MTK WiFi in squashfs"
	exit 1
}

grep -q "/sbin/wifi config" "$SQUASHFS_CHECK/etc/uci-defaults/zz_qihoo_360t7-defaults" || {
	echo "360T7 late uci-defaults does not call upstream WiFi config generator in squashfs"
	exit 1
}

grep -q "0.0.0.0:80" "$SQUASHFS_CHECK/etc/config/uhttpd" || {
	echo "uhttpd does not listen on 0.0.0.0:80 in squashfs"
	exit 1
}

grep -q "0.0.0.0:443" "$SQUASHFS_CHECK/etc/config/uhttpd" || {
	echo "uhttpd does not listen on 0.0.0.0:443 in squashfs"
	exit 1
}

check_lan_dhcp_enabled "$SQUASHFS_CHECK/etc/config/dhcp" || {
	echo "LAN DHCP defaults are not enabled in squashfs, or WAN DHCP server is not ignored"
	exit 1
}

check_file_sha256 "$SQUASHFS_CHECK/www/luci-static/argon/background/bg1.jpg" "$BG_SHA"

grep -q "^mt_wifi" "$SQUASHFS_CHECK/etc/modules.d/mt_wifi" || {
	echo "mt_wifi is not configured for module autoload in squashfs"
	exit 1
}

for path in \
	etc/wireless/l1profile.dat \
	etc/wireless/mediatek/mt7981.dbdc.b0.dat \
	etc/wireless/mediatek/mt7981.dbdc.b1.dat
do
	[ -s "$SQUASHFS_CHECK/$path" ] || {
		echo "Missing MTK WiFi profile data in squashfs: $path"
		exit 1
	}
	ls -l "$SQUASHFS_CHECK/$path"
done

grep -q "option primary '#5aa79a'" "$SQUASHFS_CHECK/etc/config/argon" || {
	echo "Argon primary color was not applied in squashfs"
	exit 1
}

grep -q "option online_wallpaper 'none'" "$SQUASHFS_CHECK/etc/config/argon" || {
	echo "Argon local wallpaper mode was not applied in squashfs"
	exit 1
}

rm -rf "$SQUASHFS_CHECK"

echo "== $(date -Is) collect output =="
rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"
find ./bin/targets -type f \( \
	-iname '*qihoo*360t7*' -o \
	-iname '*.manifest' -o \
	-iname '*sha256sums' -o \
	-iname '*.buildinfo' -o \
	-iname '*.json' \
\) -exec cp -v {} "$OUTDIR" \;
find "$OUTDIR" -maxdepth 1 -type f -print0 | xargs -0 -r sha256sum > "$OUTDIR/SHA256SUMS.local"
ls -lh "$OUTDIR"

echo "== $(date -Is) done =="
