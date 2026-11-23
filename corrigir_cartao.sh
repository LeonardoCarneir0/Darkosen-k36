#!/usr/bin/env bash
set -euo pipefail

DEV="${1:-/dev/sda}"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY="$BASE_DIR/rootfs_overlay"

if [[ $EUID -ne 0 ]]; then
    echo "Execute com / Run with: sudo $0 $DEV"
    exit 1
fi

# 1. Remove temporary udev inhibit rule if present
if [[ -f /run/udev/rules.d/90-udisks-inhibit.rules ]]; then
    rm -f /run/udev/rules.d/90-udisks-inhibit.rules
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger --subsystem-match=block 2>/dev/null || true
fi

for p in "${DEV}"*; do umount "$p" 2>/dev/null || true; done

MNT_BOOT="$(mktemp -d)"
MNT_ROOT="$(mktemp -d)"
mount "${DEV}1" "$MNT_BOOT"
mount "${DEV}2" "$MNT_ROOT"

echo "[1/5] Installing clean ArkOS K36 Kernel (717MB real RAM), calibrated DTB (spk-volume = 0x03) and dArkOSen boot logos..."
if [[ -f "$BASE_DIR/Image_arkos_k36" ]]; then
    install -m 644 "$BASE_DIR/Image_arkos_k36" "$MNT_BOOT/Image"
fi
if [[ -f "$BASE_DIR/uInitrd_arkos_k36" ]]; then
    install -m 644 "$BASE_DIR/uInitrd_arkos_k36" "$MNT_BOOT/uInitrd"
fi
install -m 644 "$BASE_DIR/rf3536k4ka.dtb" "$MNT_BOOT/rf3536k4ka.dtb"
install -m 644 "$BASE_DIR/rf3536k3ka.dtb" "$MNT_BOOT/rf3536k3ka.dtb"

if [[ -f "$BASE_DIR/darkosen_logo_640x480.bmp" ]]; then
    install -m 644 "$BASE_DIR/darkosen_logo_640x480.bmp" "$MNT_BOOT/logo.bmp"
    install -m 644 "$BASE_DIR/darkosen_logo_640x480.bmp" "$MNT_BOOT/logo_kernel.bmp"
    rm -rf "$MNT_BOOT/BMPs"/* 2>/dev/null || true
    mkdir -p "$MNT_BOOT/BMPs"
    install -m 644 "$BASE_DIR/darkosen_logo_640x480.bmp" "$MNT_BOOT/BMPs/logo.bmp"
fi
if [[ -d "$BASE_DIR/battery_bmps" ]]; then
    for bfile in "$BASE_DIR/battery_bmps"/battery_*.bmp; do
        [[ -f "$bfile" ]] && install -m 644 "$bfile" "$MNT_BOOT/$(basename "$bfile")"
    done
fi

echo "[2/5] Applying ArkOS K36 audio state (asound.state + spktoggle + fixvolume) and libfuse2..."
if [[ -f "$OVERLAY/usr/lib/aarch64-linux-gnu/libfuse.so.2.9.9" ]]; then
    install -m 644 "$OVERLAY/usr/lib/aarch64-linux-gnu/libfuse.so.2.9.9" \
        "$MNT_ROOT/usr/lib/aarch64-linux-gnu/libfuse.so.2.9.9"
    ln -sfn "libfuse.so.2.9.9" "$MNT_ROOT/usr/lib/aarch64-linux-gnu/libfuse.so.2"
fi
if [[ -f "$OVERLAY/etc/asound.state.k36" ]]; then
    mkdir -p "$MNT_ROOT/var/local" "$MNT_ROOT/var/lib/alsa"
    install -m 644 "$OVERLAY/etc/asound.state.k36" "$MNT_ROOT/var/local/asound.state"
    install -m 644 "$OVERLAY/etc/asound.state.k36" "$MNT_ROOT/var/lib/alsa/asound.state"
fi

cat > "$MNT_ROOT/usr/local/bin/fixvolume.sh" << 'EOF'
#!/bin/bash
amixer -c 0 cset iface=MIXER,name='Playback Path' SPK >/dev/null 2>&1 || true
amixer -c 0 cset iface=MIXER,name='Speaker Switch' on >/dev/null 2>&1 || true
amixer -c 0 cset iface=MIXER,name='Playback Volume' 220,220 >/dev/null 2>&1 || true
exit 0
EOF
chmod 755 "$MNT_ROOT/usr/local/bin/fixvolume.sh"

cat > "$MNT_ROOT/usr/local/bin/spktoggle.sh" << 'EOF'
#!/bin/bash
if [ -f "/var/local/asound.state" ]; then
    /usr/sbin/alsactl restore -f /var/local/asound.state >/dev/null 2>&1 || true
fi
EOF
chmod 755 "$MNT_ROOT/usr/local/bin/spktoggle.sh"

# Ensure Mali UK 11.38 (r13p0-gbm) symlinks match Kernel 5.10.160 (g18p0)
ln -sfn "libmali-bifrost-g31-rxp0-gbm.so" "$MNT_ROOT/usr/lib/aarch64-linux-gnu/libMali.so"
ln -sfn "libmali-bifrost-g31-rxp0-gbm.so" "$MNT_ROOT/usr/lib/arm-linux-gnueabihf/libMali.so"

echo "[3/5] Fixing A/B button orientation in EmulationStation and RetroArch (A = Confirm, B = Back)..."
if [[ -f "$MNT_ROOT/home/ark/.emulationstation/es_settings.cfg" ]]; then
    sed -i 's/<bool name="InvertButtons" value="true" \/>/<bool name="InvertButtons" value="false" \/>/g' \
        "$MNT_ROOT/home/ark/.emulationstation/es_settings.cfg"
fi

for rcfg in "$MNT_ROOT/home/ark/.config/retroarch/retroarch.cfg" "$MNT_ROOT/home/ark/.config/retroarch32/retroarch.cfg"; do
    if [[ -f "$rcfg" ]]; then
        sed -i 's/menu_swap_ok_cancel_buttons = "true"/menu_swap_ok_cancel_buttons = "false"/g' "$rcfg"
    fi
done

echo "[4/5] Installing persistent clock service (without RTC battery) and Change Time.sh..."
# Automatically inherit host timezone if available, otherwise keep existing / UTC
if [[ -L /etc/localtime ]]; then
    HOST_TZ="$(readlink -f /etc/localtime | sed 's|^/usr/share/zoneinfo/||')"
    if [[ -f "$MNT_ROOT/usr/share/zoneinfo/$HOST_TZ" ]]; then
        ln -sfn "/usr/share/zoneinfo/$HOST_TZ" "$MNT_ROOT/etc/localtime"
        echo "$HOST_TZ" > "$MNT_ROOT/etc/timezone"
    fi
fi

mkdir -p "$MNT_ROOT/var/lib/systemd/timesync"
touch "$MNT_ROOT/var/lib/systemd/timesync/clock"

cat > "$MNT_ROOT/etc/systemd/system/save-clock.service" << 'EOF'
[Unit]
Description=Save and restore system clock across reboots without RTC battery
DefaultDependencies=no
Before=sysinit.target shutdown.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'if [ -f /var/lib/systemd/timesync/clock ]; then SAVED=$(stat -c %Y /var/lib/systemd/timesync/clock); NOW=$(date +%s); [ "$SAVED" -gt "$NOW" ] && date -s "@$SAVED" >/dev/null 2>&1 || true; fi'
ExecStop=/bin/touch /var/lib/systemd/timesync/clock

[Install]
WantedBy=sysinit.target
EOF
ln -sfn "/etc/systemd/system/save-clock.service" "$MNT_ROOT/etc/systemd/system/sysinit.target.wants/save-clock.service" 2>/dev/null || \
ln -sfn "/etc/systemd/system/save-clock.service" "$MNT_ROOT/etc/systemd/system/multi-user.target.wants/save-clock.service"

if [[ -f "$OVERLAY/usr/local/bin/change_time_k36.sh" ]]; then
    install -m 755 "$OVERLAY/usr/local/bin/change_time_k36.sh" "$MNT_ROOT/opt/system/System/Change Time.sh"
fi

echo "[5/5] Cleaning temporary folders (/tempthemes, /roms.tar), syncing and mounting EASYROMS..."
rm -rf "$MNT_ROOT/tempthemes" "$MNT_ROOT/roms.tar" 2>/dev/null || true
chown -R 1000:1000 "$MNT_ROOT/home/ark/.emulationstation" "$MNT_ROOT/home/ark/.config/retroarch" "$MNT_ROOT/home/ark/.config/retroarch32"
sync
umount "$MNT_BOOT"
umount "$MNT_ROOT"
rmdir "$MNT_BOOT" "$MNT_ROOT"

if [[ -n "${SUDO_USER:-}" ]]; then
    sudo -u "$SUDO_USER" udisksctl mount -b "${DEV}3" 2>/dev/null || true
fi

echo "=================================================================="
echo " DONE! Clean Kernel, Audio 0x03, dArkOSen Logos and Clock OK!"
echo "=================================================================="
