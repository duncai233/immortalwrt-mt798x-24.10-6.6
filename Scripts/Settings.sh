#!/bin/bash

#修改默认主题
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改immortalwrt.lan关联IP
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js")
#添加编译日期标识
sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" $(find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js")

WIFI_FILE="./package/mtk/applications/mtwifi-cfg/files/mtwifi.sh"
#修改WIFI名称
sed -i "s/ImmortalWrt/$WRT_SSID/g" $WIFI_FILE
#修改WIFI加密
sed -i "s/encryption=.*/encryption='psk2+ccmp'/g" $WIFI_FILE
#修改WIFI密码
sed -i "/set wireless.default_\${dev}.encryption='psk2+ccmp'/a \\\t\t\t\t\t\set wireless.default_\${dev}.key='$WRT_WORD'" $WIFI_FILE

CFG_FILE="./package/base-files/files/bin/config_generate"
#修改默认IP地址
sed -i '/^\s*static\)/,/^;;/c\
	    static)
	    local ipad netm
    	if [ "$1" = "lan" ]; then
        	ipad=${ipaddr:-"'$WRT_IP'"}
        	netm=${netmask:-"255.0.0.0"}
    	else
        	ipad=${ipaddr:-"172.$((16 + addr_offset)).0.1"}
        	netm=${netmask:-"255.255.0.0"}
        	addr_offset=$((addr_offset+1))
	    fi
    	uci -q batch <<-EOF
        	set network.$1.proto='static'
	        set network.$1.ipaddr='$ipad'
    	    set network.$1.netmask='$netm'
	    EOF
    	[ -e /proc/sys/net/ipv6 ] && uci set network.$1.ip6assign='60'
	;;' "$CFG_FILE"
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE

#配置文件修改
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi
