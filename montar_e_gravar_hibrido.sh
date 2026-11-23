#!/usr/bin/env bash
# ==============================================================================
# montar_e_gravar_hibrido.sh — darkosen-k36
# Builds and flashes a hybrid SD card (>= 16 GB) for R36S-V20 2025-05-18 (2549) / K36:
#   - Bootloader GPT (16 MB, DDR V2.08 @ 333MHz) + BOOT partition (500 MB) +
#     clean Kernel 5.10.160 directly from ArkOS_K36.img
#   - Calibrated DTB (RK3326-S 1.10V/1296MHz + Xinyuwei 768MB @ 328MHz + spk-volume 0x03)
#   - Full dArkOSen Debian 13 (Trixie, glibc 2.41) rootfs converted to ext4
#     with Kernel 5.10.160 modules, Mali UK 11.38, libfuse2, play_joystick, ZRam 512MB lz4,
#     hp_autoswitch, dArkOSen boot/battery logos and persistent clock.
#
# Usage:
#   sudo ./montar_e_gravar_hibrido.sh /dev/sdX /path/to/ArkOS_K36.img /path/to/dArkOSen.img
# ==============================================================================
set -euo pipefail

DEV="${1:-}"
K36_IMG="${2:-}"
DARKOS_IMG="${3:-}"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY="$BASE_DIR/rootfs_overlay"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run with sudo:"
    echo "  sudo $0 /dev/sdX [/path/to/ArkOS_K36.img] [/path/to/dArkOSen.img]"
    exit 1
fi

if [[ -z "$DEV" ]]; then
    echo "Usage: sudo $0 /dev/sdX [/path/to/ArkOS_K36.img] [/path/to/dArkOSen.img]"
    exit 1
fi

# Auto-detect images in BASE_DIR if not passed as arguments
if [[ -z "$K36_IMG" ]]; then
    K36_IMG="$(find "$BASE_DIR" -maxdepth 1 -iname '*ArkOS*K36*.img' | head -1 || true)"
fi
if [[ -z "$DARKOS_IMG" ]]; then
    DARKOS_IMG="$(find "$BASE_DIR" -maxdepth 1 -iname '*dArkOS*.img' | head -1 || true)"
fi

# 1. Safety guard against flashing internal NVMe / non-removable drives
if [[ "$DEV" == *nvme* ]] || [[ ! -b "$DEV" ]]; then
    echo "ABORTED: '$DEV' does not exist or is an internal NVMe drive!" >&2
    exit 1
fi

DEV_NAME="$(basename "$DEV")"
if [[ "$(cat "/sys/block/$DEV_NAME/removable" 2>/dev/null || echo 0)" != "1" ]]; then
    echo "ABORTED: '$DEV' is not marked as a removable disk (RM=1)!" >&2
    exit 1
fi

DISK_SECTORS="$(cat "/sys/block/$DEV_NAME/size")"
P1_START=32768
P1_END=1056767
P2_START=1056768
P2_END=20979711   # 9.5 GiB (supports any SD card >= 16 GB: 16/32/64/128/256/512 GB+)
P3_START=20979712
P3_END=$(( DISK_SECTORS - 35 ))

if (( DISK_SECTORS <= P3_START + 204800 )); then
    echo "ABORTED: Target SD card ($DEV) is smaller than 16 GB! Use a 16 GB or larger card." >&2
    exit 1
fi

echo "=================================================================="
echo " darkosen-k36 — Hybrid dArkOSen (Debian 13) + ArkOS K36 5.10.160"
echo " Target device : $DEV ($(lsblk -dno SIZE,MODEL "$DEV" 2>/dev/null))"
echo " ArkOS K36 img : ${K36_IMG:-using local bootloader_16M.bin + boot_500M.fat}"
echo " dArkOSen img  : ${DARKOS_IMG:-auto}"
echo "=================================================================="

# 2. Mount dArkOSen rootfs (read-only) via loop device
SRC_ROOT=""
LOOP_DEV=""
TMP_SRC=""
TMP_ROMS_TAR=""

cleanup() {
    if [[ -n "$TMP_SRC" && -d "$TMP_SRC" ]]; then
        umount "$TMP_SRC" 2>/dev/null || true
        rmdir "$TMP_SRC" 2>/dev/null || true
    fi
    if [[ -n "$LOOP_DEV" ]]; then
        losetup -d "$LOOP_DEV" 2>/dev/null || true
    fi
    if [[ -n "$TMP_ROMS_TAR" && -f "$TMP_ROMS_TAR" ]]; then
        rm -f "$TMP_ROMS_TAR" 2>/dev/null || true
    fi
}
trap cleanup EXIT

if [[ -n "$DARKOS_IMG" && -f "$DARKOS_IMG" ]]; then
    echo "[1/7] Mounting $DARKOS_IMG (read-only) to extract Debian 13 rootfs..."
    TMP_SRC="$(mktemp -d)"
    LOOP_DEV="$(losetup --show -f -P -r "$DARKOS_IMG")"
    mount -o ro "${LOOP_DEV}p2" "$TMP_SRC"
    SRC_ROOT="$TMP_SRC"
else
    echo "ERROR: dArkOSen .img file not found! Pass it as the 3rd argument:" >&2
    echo "  sudo $0 $DEV /path/to/ArkOS_K36.img /path/to/dArkOSen.img" >&2
    exit 1
fi

# Unmount any mounted partitions on target SD card
for p in "${DEV}"*; do umount "$p" 2>/dev/null || true; done

# 3. Flash first 16 MB (GPT + DDR V2.08 + U-Boot K36 + Trust) + 500 MB BOOT partition
echo "[2/7] Flashing K36 Bootloader (16 MB) and BOOT partition (500 MB) to $DEV..."
if [[ -n "$K36_IMG" && -f "$K36_IMG" ]]; then
    dd if="$K36_IMG" of="$DEV" bs=1M count=516 conv=notrunc status=progress
elif [[ -f "$BASE_DIR/bootloader_16M.bin" && -f "$BASE_DIR/boot_500M.fat" ]]; then
    dd if="$BASE_DIR/bootloader_16M.bin" of="$DEV" bs=1M count=16 conv=notrunc status=none
    dd if="$BASE_DIR/boot_500M.fat" of="$DEV" bs=1M seek=16 count=500 conv=notrunc status=progress
else
    echo "ERROR: ArkOS K36 .img not found! Pass it as the 2nd argument." >&2
    exit 1
fi
sync

# 4. Recreate GPT partition table dynamically matching the exact SD card size
echo "[3/7] Creating dynamic GPT layout (500M BOOT + 9.5G ROOTFS ext4 + remaining EASYROMS exFAT)..."
gdisk "$DEV" >/dev/null <<EOF
x
e
m
d
2
n
2
$P2_START
$P2_END
8300
n
3
$P3_START
$P3_END
0700
c
1
boot
c
2
root
c
3
EASYROMS
w
y
y
EOF

blockdev --rereadpt "$DEV" 2>/dev/null || partprobe "$DEV" 2>/dev/null || true
udevadm settle 2>/dev/null || true
sleep 3
for p in "${DEV}"*; do umount "$p" 2>/dev/null || true; done

# 5. Inject calibrated DTB, extlinux.conf and dArkOSen boot/battery logos into BOOT
echo "[4/7] Applying calibrated DTB (328 MHz RAM, spk-volume 0x03) and dArkOSen logos to ${DEV}1..."
fsck.fat -a "${DEV}1" >/dev/null 2>&1 || true
MNT_BOOT="$(mktemp -d)"
mount "${DEV}1" "$MNT_BOOT"
cp -f "$MNT_BOOT/rf3536k4ka.dtb" "$MNT_BOOT/rf3536k4ka.dtb.orig" 2>/dev/null || true
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

mkdir -p "$MNT_BOOT/extlinux"
cat > "$MNT_BOOT/extlinux/extlinux.conf" << 'EOF'
LABEL ArkOS
  LINUX /Image
  FDT /rf3536k4ka.dtb
  INITRD /uInitrd
  APPEND earlyprintk console=ttyFIQ0 rw root=/dev/mmcblk1p2 rootfstype=ext4 loglevel=7 init=/sbin/init rootwait rootdelay=10 fsck.repair=yes fbcon=rotate:0 quiet splash plymouth.ignore-serial-consoles consoleblank=0
EOF
sync
umount "$MNT_BOOT"
rmdir "$MNT_BOOT"

# 6. Format ROOTFS as ext4 (compatible with uInitrd e2fsck) and transplant Debian 13 + K36 drivers
echo "[5/7] Formatting ${DEV}2 as ext4 and copying dArkOSen Debian 13 rootfs (~2-4 min)..."
mkfs.ext4 -F -L ROOTFS -O ^orphan_file,^metadata_csum_seed "${DEV}2"
MNT_ROOT="$(mktemp -d)"
mount "${DEV}2" "$MNT_ROOT"

rsync -aAX --info=progress2 \
    --exclude='/roms.tar' \
    --exclude='/tempthemes' \
    --exclude='/proc/*' \
    --exclude='/sys/*' \
    --exclude='/dev/*' \
    --exclude='/run/*' \
    "$SRC_ROOT/" "$MNT_ROOT/"

echo "  -> Injecting Kernel 5.10.160 modules, Mali UK 11.38, libfuse2, exfat-fuse, audio and play_joystick..."
mkdir -p "$MNT_ROOT/usr/lib/modules" "$MNT_ROOT/opt/system/Tools" "$MNT_ROOT/var/local" "$MNT_ROOT/var/lib/alsa"
cp -a "$OVERLAY/usr/lib/modules/5.10.160-gb9111f792d94-dirty" "$MNT_ROOT/usr/lib/modules/"
for kver in "5.10.160-gc18be26ca0ba-dirty" "5.10.160-ge8de3988c23f-dirty" "5.10.160-g4c735a3db925-dirty"; do
    ln -sfn "5.10.160-gb9111f792d94-dirty" "$MNT_ROOT/usr/lib/modules/$kver"
done

# Mali Bifrost r13p0 (UK 11.38) matching Kernel 5.10.160 (g18p0)
ln -sfn "libmali-bifrost-g31-rxp0-gbm.so" "$MNT_ROOT/usr/lib/aarch64-linux-gnu/libMali.so"
ln -sfn "libmali-bifrost-g31-rxp0-gbm.so" "$MNT_ROOT/usr/lib/arm-linux-gnueabihf/libMali.so"

# exFAT FUSE + libfuse.so.2 for Debian 13
install -m 644 "$OVERLAY/usr/lib/aarch64-linux-gnu/libfuse.so.2.9.9" \
    "$MNT_ROOT/usr/lib/aarch64-linux-gnu/libfuse.so.2.9.9"
ln -sfn "libfuse.so.2.9.9" "$MNT_ROOT/usr/lib/aarch64-linux-gnu/libfuse.so.2"
install -m 755 "$OVERLAY/usr/sbin/mount.exfat-fuse" "$MNT_ROOT/usr/sbin/mount.exfat-fuse"
ln -sfn "mount.exfat-fuse" "$MNT_ROOT/usr/sbin/mount.exfat"
ln -sfn "/usr/sbin/mount.exfat-fuse" "$MNT_ROOT/sbin/mount.exfat" 2>/dev/null || true

# Audio state from ArkOS K36 + fixvolume + spktoggle
install -m 644 "$OVERLAY/etc/asound.state.k36" "$MNT_ROOT/var/local/asound.state"
install -m 644 "$OVERLAY/etc/asound.state.k36" "$MNT_ROOT/var/lib/alsa/asound.state"

for bin in "$OVERLAY/usr/local/bin/"*; do
    [[ -f "$bin" ]] || continue
    install -m 755 "$bin" "$MNT_ROOT/usr/local/bin/$(basename "$bin")"
done
install -m 755 "$OVERLAY/usr/local/bin/zram-autostart.sh" "$MNT_ROOT/usr/local/bin/zram_autostart.sh"

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

# Patch fn_menu_watcher.sh for play_joystick
if [[ -f "$MNT_ROOT/usr/local/bin/fn_menu_watcher.sh" ]]; then
    sed -i 's/Name="GO-Super Gamepad"/Name="play_joystick"/g' "$MNT_ROOT/usr/local/bin/fn_menu_watcher.sh"
    sed -i 's/if \[\[ "\$LINE" == \*"BTN_TRIGGER_HAPPY5"\*.*\]; then/if [[ "$LINE" == *"BTN_TRIGGER_HAPPY5"* || "$LINE" == *"KEY_FN"* || "$LINE" == *"BTN_MODE"* ]]; then/' "$MNT_ROOT/usr/local/bin/fn_menu_watcher.sh"
fi

# Adjust mmcblk0p3 -> mmcblk1p3 in dArkOS scripts
for sc in "$MNT_ROOT/usr/local/bin/Scan_SD1p3.sh" "$MNT_ROOT/usr/local/bin/Switch to Main SD for Roms.sh"; do
    [[ -f "$sc" ]] && sed -i 's/mmcblk0p3/mmcblk1p3/g' "$sc"
done

# Lock RAM frequency to 328 MHz and CPU ceiling to 1296 MHz
echo "FREQ=328000000" > "$MNT_ROOT/etc/dmc-settings.conf"
echo -e "GOV=ondemand\nFREQ=1296000" > "$MNT_ROOT/etc/cpu-settings.conf"

# play_joystick mappings + A/B orientation (A = Confirm, B = Back)
install -m 644 "$OVERLAY/etc/emulationstation/es_input.cfg" "$MNT_ROOT/etc/emulationstation/es_input.cfg"
cp -f "$OVERLAY/etc/emulationstation/es_input.cfg" "$MNT_ROOT/home/ark/.quirks/es_input.cfg" 2>/dev/null || true
cp -a "$OVERLAY/home/ark/pmk36" "$MNT_ROOT/home/ark/"

if [[ -f "$MNT_ROOT/home/ark/.emulationstation/es_settings.cfg" ]]; then
    sed -i 's/<bool name="InvertButtons" value="true" \/>/<bool name="InvertButtons" value="false" \/>/g' \
        "$MNT_ROOT/home/ark/.emulationstation/es_settings.cfg"
fi

PJ_LINE="19000f6a706c61795f6a6f7973746900,play_joystick,a:b0,b:b1,x:b2,y:b3,back:b8,guide:b10,start:b9,leftstick:b11,rightstick:b12,leftshoulder:b4,rightshoulder:b5,dpup:b14,dpdown:b15,dpleft:b16,dpright:b17,leftx:a0,lefty:a3,rightx:a2,righty:a1,lefttrigger:b6,righttrigger:b7,platform:Linux,"
for gcdb in "$MNT_ROOT/opt/inttools/gamecontrollerdb.txt" "$MNT_ROOT/usr/bin/emulationstation/resources/gamecontrollerdb.txt"; do
    if [[ -f "$gcdb" ]] && ! grep -q "19000f6a706c61795f6a6f7973746900" "$gcdb"; then
        echo "$PJ_LINE" >> "$gcdb"
    fi
done

python3 - "$MNT_ROOT" "$OVERLAY" << 'PYPATCH'
import sys, os, re

mnt_root, overlay = sys.argv[1], sys.argv[2]

def load_k36_inputs(path):
    inputs = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line.startswith(("input_player1_", "input_enable_hotkey", "input_exit_emulator", "input_menu_toggle", "input_joypad_driver")) and "=" in line:
                k, v = [x.strip() for x in line.split("=", 1)]
                inputs[k] = v
    return inputs

for sub in ["retroarch", "retroarch32"]:
    k36_cfg = os.path.join(overlay, "home/ark/.config", sub, "retroarch.cfg.k36")
    target_cfg = os.path.join(mnt_root, "home/ark/.config", sub, "retroarch.cfg")
    if not os.path.exists(k36_cfg) or not os.path.exists(target_cfg):
        continue
    k36_in = load_k36_inputs(k36_cfg)
    k36_in["menu_swap_ok_cancel_buttons"] = '"false"'
    with open(target_cfg) as f:
        lines = f.readlines()
    seen = set()
    out = []
    for line in lines:
        m = re.match(r"^\s*([a-zA-Z0-9_]+)\s*=", line)
        if m and m.group(1) in k36_in:
            k = m.group(1)
            out.append(f"{k} = {k36_in[k]}\n")
            seen.add(k)
        else:
            out.append(line)
    for k, v in k36_in.items():
        if k not in seen:
            out.append(f"{k} = {v}\n")
    with open(target_cfg, "w") as f:
        f.writelines(out)
PYPATCH

# /etc/fstab with nofail + ZRam 512MB lz4 + hp_autoswitch + persistent clock
cat > "$MNT_ROOT/etc/fstab" << 'EOF'
/dev/mmcblk1p2  /                  ext4   defaults,noatime                                             0 1
/dev/mmcblk1p1  /boot              vfat   defaults,nofail                                              0 2
/dev/mmcblk1p3  /roms              exfat  defaults,auto,nofail,umask=000,uid=1000,gid=1000,noatime     0 0
/roms/tools     /opt/system/Tools  none   nofail,x-systemd.device-timeout=7,bind                       0 0
EOF

cat > "$MNT_ROOT/etc/zram.conf" << 'EOF'
ENABLED=1
ALGORITHM=lz4
SIZE=536870912
ZRAM_SIZE_MB=512
ZRAM_ALGORITHM=lz4
EOF

install -m 644 "$OVERLAY/etc/systemd/system/hp_autoswitch.service" "$MNT_ROOT/etc/systemd/system/hp_autoswitch.service"
ln -sfn "/etc/systemd/system/hp_autoswitch.service" "$MNT_ROOT/etc/systemd/system/multi-user.target.wants/hp_autoswitch.service"
rm -f "$MNT_ROOT/etc/systemd/system/multi-user.target.wants/zram-swap.service" \
      "$MNT_ROOT/etc/systemd/system/swap.target.wants/zram-swap.service" \
      "$MNT_ROOT/etc/systemd/system/zram-swap.service" \
      "$MNT_ROOT/etc/systemd/system/multi-user.target.wants/firstboot.service"

# Inherit host timezone + install persistent clock service & Change Time.sh
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

ln -sfn "/roms/themes" "$MNT_ROOT/home/ark/.emulationstation/themes"
ln -sfn "/roms/themes" "$MNT_ROOT/etc/emulationstation/themes"
chown -R 1000:1000 "$MNT_ROOT/home/ark"
sync
umount "$MNT_ROOT"
rmdir "$MNT_ROOT"

# 7. Format EASYROMS (exFAT), extract roms.tar + themes directly from dArkOSen image
echo "[6/7] Formatting ${DEV}3 (EASYROMS) as exFAT and populating ROM folders, themes & PortMaster..."
mkfs.exfat -n EASYROMS "${DEV}3"
MNT_ROMS="$(mktemp -d)"
mount "${DEV}3" "$MNT_ROMS"

if [[ -f "$SRC_ROOT/roms.tar" ]]; then
    echo "  -> Extracting roms.tar from dArkOSen image..."
    tar --warning=no-timestamp --no-same-permissions --no-same-owner --hard-dereference --strip-components=1 -xf "$SRC_ROOT/roms.tar" -C "$MNT_ROMS" || true
fi

mkdir -p "$MNT_ROMS/themes" "$MNT_ROMS/tools/PortMaster" "$MNT_ROMS/ports/PortMaster"
if [[ -d "$SRC_ROOT/tempthemes" ]]; then
    echo "  -> Copying EmulationStation themes..."
    cp -rf "$SRC_ROOT/tempthemes/"* "$MNT_ROMS/themes/" 2>/dev/null || true
fi

install -m 755 "$BASE_DIR/Diagnostico_Hardware_Real.sh" "$MNT_ROMS/tools/Diagnostico_Hardware_Real.sh" 2>/dev/null || true
cp -f "$OVERLAY/home/ark/pmk36/control.txt" "$MNT_ROMS/tools/PortMaster/" 2>/dev/null || true
cp -f "$OVERLAY/home/ark/pmk36/gamecontrollerdb.txt" "$MNT_ROMS/tools/PortMaster/" 2>/dev/null || true
cp -f "$OVERLAY/home/ark/pmk36/control.txt" "$MNT_ROMS/ports/PortMaster/" 2>/dev/null || true
cp -f "$OVERLAY/home/ark/pmk36/gamecontrollerdb.txt" "$MNT_ROMS/ports/PortMaster/" 2>/dev/null || true

sync
umount "$MNT_ROMS"
rmdir "$MNT_ROMS"

echo "[7/7] Syncing write buffers..."
sync
if [[ -n "${SUDO_USER:-}" ]]; then
    sudo -u "$SUDO_USER" udisksctl mount -b "${DEV}3" 2>/dev/null || true
fi

echo "=================================================================="
echo " SUCCESS! Your darkosen-k36 SD card ($DEV) is 100% ready."
echo " Insert it into TF1 on your R36S-V20 / K36 and power on!"
echo "=================================================================="
