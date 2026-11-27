"""
Centralized configuration, directory layout, partition geometry constants,
and system configuration templates for darkosen-k36.
"""

from __future__ import annotations

from pathlib import Path
from typing import Optional

# Repository directory hierarchy
PACKAGE_DIR = Path(__file__).resolve().parent
REPO_ROOT = PACKAGE_DIR.parent

ASSETS_DIR = REPO_ROOT / "assets"
AUDIO_DIR = ASSETS_DIR / "audio"
LOGOS_DIR = ASSETS_DIR / "boot_logos"
BATTERY_BMPS_DIR = LOGOS_DIR / "battery_bmps"
CONTROLS_DIR = ASSETS_DIR / "controls"
DEVICE_TOOLS_DIR = ASSETS_DIR / "device_tools"
DTB_DIR = ASSETS_DIR / "dtb"
KERNEL_DIR = ASSETS_DIR / "kernel"
KERNEL_MODULES_ARCHIVE = KERNEL_DIR / "modules-5.10.160.tar.zst"
NETWORK_DIR = ASSETS_DIR / "network"
SYSTEM_DIR = ASSETS_DIR / "system"

DOCS_DIR = REPO_ROOT / "docs"
CACHE_DIR = REPO_ROOT / "cache"

# GPT Partition geometry (in 512-byte sectors)
P1_START = 32768       # 16 MiB offset (after Rockchip bootloader stack)
P1_END = 1056767       # +500 MiB (BOOT FAT16 partition)
P2_START = 1056768     # Start of ROOTFS (ext4)

REQUIRED_HOST_TOOLS: tuple[str, ...] = (
    "dd",
    "gdisk",
    "mkfs.ext4",
    "mkfs.exfat",
    "rsync",
    "losetup",
    "mount",
    "umount",
    "tar",
    "e2fsck",
    "resize2fs",
    "lsblk",
)

REQUIRED_ASSETS: tuple[Path, ...] = (
    DTB_DIR / "rf3536k4ka.dtb",
    DTB_DIR / "rf3536k4ka_ram_test_666.dtb",
    LOGOS_DIR / "darkosen_logo_640x480.bmp",
    AUDIO_DIR / "asound.state.k36",
    AUDIO_DIR / "hp_autoswitch.sh",
    AUDIO_DIR / "hp_autoswitch.service",
    CONTROLS_DIR / "es_input.cfg",
    CONTROLS_DIR / "pmk36/gamecontrollerdb.txt",
    SYSTEM_DIR / "libs/aarch64/libfuse.so.2.9.9",
    SYSTEM_DIR / "bin/mount.exfat-fuse",
    SYSTEM_DIR / "bin/change_time_k36.sh",
    DEVICE_TOOLS_DIR / "Diagnostico_Hardware_Real.sh",
    DEVICE_TOOLS_DIR / "Testar_RAM_Frequencia.sh",
)

PJ_GCDB_LINE = (
    "19000f6a706c61795f6a6f7973746900,play_joystick,"
    "a:b0,b:b1,x:b2,y:b3,back:b8,guide:b10,start:b9,"
    "leftstick:b11,rightstick:b12,leftshoulder:b4,rightshoulder:b5,"
    "dpup:b14,dpdown:b15,dpleft:b16,dpright:b17,"
    "leftx:a0,lefty:a3,rightx:a2,righty:a1,lefttrigger:b6,righttrigger:b7,platform:Linux,"
)

EXTLINUX_CONF = """LABEL ArkOS
  LINUX /Image
  FDT /rf3536k4ka.dtb
  INITRD /uInitrd
  APPEND earlyprintk console=ttyFIQ0 rw root=/dev/mmcblk1p2 rootfstype=ext4 loglevel=7 init=/sbin/init rootwait rootdelay=10 fsck.repair=yes fbcon=rotate:0 quiet splash plymouth.ignore-serial-consoles consoleblank=0
"""

FSTAB_CONTENT = """/dev/mmcblk1p2  /                  ext4   defaults,noatime                                             0 1
/dev/mmcblk1p1  /boot              vfat   defaults,nofail                                              0 2
/dev/mmcblk1p3  /roms              exfat  defaults,auto,nofail,umask=000,uid=1000,gid=1000,noatime     0 0
/roms/tools     /opt/system/Tools  none   nofail,x-systemd.device-timeout=7,bind                       0 0
"""

ZRAM_CONF = """ENABLED=1
ALGORITHM=lz4
SIZE=536870912
ZRAM_SIZE_MB=512
ZRAM_ALGORITHM=lz4
"""

FIXVOLUME_SH = """#!/bin/bash
if ls /proc/asound/card[1-9]*/pcm0p >/dev/null 2>&1; then
    amixer -c 0 cset iface=MIXER,name='Playback Path' OFF >/dev/null 2>&1 || true
elif amixer -c 0 contents 2>/dev/null | grep -A2 "name='Headphone Jack'" | grep -q "values=on"; then
    amixer -c 0 cset iface=MIXER,name='Playback Path' HP >/dev/null 2>&1 || true
else
    amixer -c 0 cset iface=MIXER,name='Playback Path' SPK >/dev/null 2>&1 || true
fi
amixer -c 0 cset iface=MIXER,name='Speaker Switch' on >/dev/null 2>&1 || true
amixer -c 0 cset iface=MIXER,name='Playback Volume' 220,220 >/dev/null 2>&1 || true
exit 0
"""

SPKTOGGLE_SH = """#!/bin/bash
if [ -f "/var/local/asound.state" ]; then
    /usr/sbin/alsactl restore -f /var/local/asound.state >/dev/null 2>&1 || true
fi
"""

SAVE_CLOCK_SERVICE = """[Unit]
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
"""


def find_cached_file(filename: str) -> Optional[Path]:
    """Locate an optional binary artifact in cache/ or repository root."""
    for folder in (CACHE_DIR, REPO_ROOT):
        candidate = folder / filename
        if candidate.exists():
            return candidate
    return None


def find_cached_glob(pattern: str) -> Optional[Path]:
    """Locate the first file matching a glob pattern in cache/ or repository root."""
    for folder in (CACHE_DIR, REPO_ROOT):
        if folder.is_dir():
            match = next(iter(sorted(folder.glob(pattern))), None)
            if match is not None:
                return match
    return None
