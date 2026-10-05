#!/vendor/bin/sh
# v1.0 NET-2：开机时给热点预建第二个 Wi-Fi 接口 wlan1（STA+AP 并发要用）。
#
# 为什么要预建（2026-10-05 构建机 crDroid 树核实）：
#   * 本机的 legacy Wi-Fi HAL 是 libwifi-hal-emu（BOARD_WLAN_DEVICE := emulator，
#     frameworks/opt/net/wifi/libwifi_hal/Android.bp:184），它的函数表里没有
#     wifi_virtual_interface_create（device/generic/goldfish/wifi/wifi_hal/wifi_hal.cpp:423-486），
#     于是 HAL 走"厂商 HAL 不建接口、要求接口已存在"的分支：
#     hardware/interfaces/wifi/aidl/default/wifi_legacy_hal.cpp handleVirtualInterfaceCreateOrDeleteStatus
#     —— NOT_SUPPORTED 时只看 if_nametoindex(ifname)，接口不在就建热点失败。
#   * 热点接口名：开了 STA+AP 组合后 AP 从 idx 1 起（wifi_chip.cpp startIdxOfApIface），
#     名字按 wifi.concurrent.interface → wifi.interface.1 → "wlan1"（wifi_chip.cpp:84-101）⇒ wlan1。
#   * goldfish HAL 在 wifi_initialize 时只枚举 /sys/class/net 下的 wlan0、wlan1
#     （device/generic/goldfish/wifi/wifi_hal/info.cpp:23-37）⇒ wlan1 要在 Wi-Fi 打开之前就在。
#     万一晚于 HAL 启动才建好，关一次再开 Wi-Fi 即可（HalState::init 每次开 Wi-Fi 都重新枚举）。
#
# 副作用：建出来的 wlan1 平时是 down 的 —— mac80211 只在接口 up 时才向固件建 vdev
#   （ieee80211_do_open → drv_add_interface），所以不开热点时对固件、功耗、挂起路径（#16）都没有影响。
#   地址由 mac80211 从 ath11k 给的地址表里挑一个没用过的（mac.c ath11k_mac_setup_mac_address_list，
#   第 2 个是置了本地管理位的变体）；热点真正用的 MAC 由框架随机化后经 HAL 设置。
# 类型建成 managed：hostapd 起来时自己把它切成 AP（nl80211 驱动的 set_mode）。

i=0
while [ ! -e /sys/class/net/wlan0 ]; do
    i=$((i + 1))
    if [ "$i" -ge 120 ]; then
        log -t gaokun3-wlan "60 秒内没等到 wlan0，不建 wlan1（热点将只能与 Wi-Fi 二选一）"
        exit 0
    fi
    sleep 0.5
done

if [ -e /sys/class/net/wlan1 ]; then
    exit 0
fi

if /vendor/bin/iw dev wlan0 interface add wlan1 type managed; then
    log -t gaokun3-wlan "已建 wlan1（给热点用）：$(cat /sys/class/net/wlan1/address 2>/dev/null)"
else
    log -t gaokun3-wlan "iw 建 wlan1 失败（热点将只能与 Wi-Fi 二选一）"
fi
exit 0
