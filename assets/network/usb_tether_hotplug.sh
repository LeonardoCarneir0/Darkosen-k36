#!/bin/bash
# usb_tether_hotplug.sh - Automatic USB Tethering & USB Ethernet handler for darkosen-k36
# Supports Android (RNDIS / CDC-NCM / CDC-ECM), iPhone (ipheth), and USB-C/USB-A Ethernet adapters.

export LC_ALL=C
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

MODE="${1:-}"
TARGET="${2:-}"

log() {
    logger -t usb_tether_hotplug "$*" 2>/dev/null || true
}

case "$MODE" in
    usb-modload)
        [ -n "$TARGET" ] || exit 0
        # Fast path: standard modprobe when uname -r matches vermagic (5.10.160-gc18be26ca0ba-dirty)
        if modprobe -q -b "$TARGET" 2>/dev/null; then
            exit 0
        fi
        # Fallback for alternate 5.10.160-g*-dirty kernel builds: force-load dependency chain in order
        while read -r kind kopath _; do
            [ "$kind" = "insmod" ] && [ -f "$kopath" ] || continue
            modname="$(basename "$kopath" .ko)"
            modprobe -f "$modname" 2>/dev/null || true
        done < <(modprobe --show-depends "$TARGET" 2>/dev/null)
        ;;

    net-up)
        IFACE="$TARGET"
        [ -n "$IFACE" ] && [ -e "/sys/class/net/$IFACE" ] || exit 0

        # Skip wireless interfaces (USB Wi-Fi dongles are managed via Wi-Fi menu)
        if [ -d "/sys/class/net/$IFACE/wireless" ] || [ -d "/sys/class/net/$IFACE/phy80211" ]; then
            exit 0
        fi

        log "USB network interface detected: $IFACE"

        # Prevent USB autosuspend from dropping the phone/adapter link
        for p in "/sys/class/net/$IFACE/device/../power/control" \
                 "/sys/bus/usb/devices/usb1/power/control"; do
            [ -w "$p" ] && echo on > "$p" 2>/dev/null || true
        done

        ip link set dev "$IFACE" up 2>/dev/null || true

        # Prefer NetworkManager (Debian 13 default in dArkOSen)
        if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then
            nmcli device set "$IFACE" managed yes >/dev/null 2>&1 || true
            nmcli device connect "$IFACE" >/dev/null 2>&1 || true
        fi

        # Wait up to 6s for an IPv4 address; fallback to dhclient/udhcpc if still unassigned
        for _ in 1 2 3 4 5 6; do
            if ip -4 addr show dev "$IFACE" 2>/dev/null | grep -q "inet "; then
                log "$IFACE connected via DHCP"
                exit 0
            fi
            sleep 1
        done

        if command -v dhclient >/dev/null 2>&1; then
            log "Running dhclient fallback on $IFACE"
            dhclient -1 "$IFACE" >/dev/null 2>&1 || true
        elif command -v udhcpc >/dev/null 2>&1; then
            log "Running udhcpc fallback on $IFACE"
            udhcpc -i "$IFACE" -n -q >/dev/null 2>&1 || true
        fi
        ;;
esac
exit 0
