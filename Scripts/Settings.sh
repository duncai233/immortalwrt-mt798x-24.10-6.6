#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

set -e

# Remove luci-app-attendedsysupgrade from LuCI collections.
find ./feeds/luci/collections/ -type f -name "Makefile" -exec sed -i "/attendedsysupgrade/d" {} +

# Apply the selected default theme and login IP hints.
find ./feeds/luci/collections/ -type f -name "Makefile" -exec sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" {} +
find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js" -exec sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" {} +

# Add build mark to LuCI status.
find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js" -exec \
	sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" {} +

apply_source_patches() {
	local patch_dir="$GITHUB_WORKSPACE/Patches"
	local patch_file

	[ -d "$patch_dir" ] || return 0

	for patch_file in "$patch_dir"/*.patch; do
		[ -f "$patch_file" ] || continue
		echo "Applying source patch: $(basename "$patch_file")"
		git apply --check "$patch_file"
		git apply "$patch_file"
	done
}

fix_360t7_source_permissions() {
	local file

	[ ! -d "./package/base-files/files/etc/init.d" ] || \
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
}

install_argon_static_wallpaper() {
	local argon_config argon_static argon_bg_dir bg_image

	bg_image="$GITHUB_WORKSPACE/bg1.jpg"
	[ -s "$bg_image" ] || {
		echo "Missing required Argon background image: $bg_image"
		exit 1
	}

	argon_config=$({ find ./package ./feeds/luci -path '*/luci-app-argon-config/root/etc/config/argon' -type f 2>/dev/null || true; } | head -n 1)
	[ -n "$argon_config" ] || {
		echo "Missing luci-app-argon-config source; cannot apply Argon defaults."
		exit 1
	}

	argon_static=$({ find ./package ./feeds/luci -path '*/luci-theme-argon/htdocs/luci-static/argon' -type d 2>/dev/null || true; } | head -n 1)
	[ -n "$argon_static" ] || {
		echo "Missing luci-theme-argon static directory; cannot install bg1.jpg."
		exit 1
	}

	argon_bg_dir="$argon_static/background"
	install -d -m 0755 "$argon_bg_dir"
	install -m 0644 "$bg_image" "$argon_bg_dir/bg1.jpg"

	sed -i \
		-e "s/option primary .*/option primary '#5aa79a'/" \
		-e "s/option dark_primary .*/option dark_primary '#5aa79a'/" \
		-e "s/option font_weight .*/option font_weight 'normal'/" \
		-e "s/option transparency .*/option transparency '0.5'/" \
		-e "s/option transparency_dark .*/option transparency_dark '0.5'/" \
		-e "s/option online_wallpaper .*/option online_wallpaper 'none'/" \
		"$argon_config"
}

IS_360T7=0
if [[ "${WRT_CONFIG,,}" == *"360t7"* ]]; then
	IS_360T7=1
	apply_source_patches
	fix_360t7_source_permissions
	install_argon_static_wallpaper
fi

WIFI_FILE="./package/mtk/applications/mtwifi-cfg/files/mtwifi.sh"
if [ "$IS_360T7" != "1" ] && [ -f "$WIFI_FILE" ]; then
	sed -i "s/ImmortalWrt/immortalwrt-2.4G/g" "$WIFI_FILE"
	sed -i "s/immortalwrt-2.4G-5G/immortalwrt-5G/g" "$WIFI_FILE"
	sed -i "s/encryption=.*/encryption='psk2+ccmp'/g" "$WIFI_FILE"
	sed -i "/set wireless.default_\${dev}.encryption='psk2+ccmp'/a \\\t\t\t\t\t\set wireless.default_\${dev}.key='$WRT_WORD'" "$WIFI_FILE"
fi

CFG_FILE="./package/base-files/files/bin/config_generate"
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" "$CFG_FILE"
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" "$CFG_FILE"

cat >> ./.config <<EOF_CONFIG
CONFIG_PACKAGE_luci=y
CONFIG_LUCI_LANG_zh_Hans=y
CONFIG_PACKAGE_luci-theme-$WRT_THEME=y
CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y
EOF_CONFIG

if [ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ]; then
	echo "Applying private configurations from PRIVATE.txt..."
	cat "$GITHUB_WORKSPACE/Config/PRIVATE.txt" >> ./.config
fi

if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi

if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
	echo "WRT_WIFI=wifi-no" >> "$GITHUB_ENV"
fi
