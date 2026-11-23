#!/usr/bin/env python3
"""
darkosen_k36.py — Unified hybrid firmware builder & patcher for R36S-V20 2025-05-18 (Batch 2549) / K36
Combines the ArkOS K36 low-level hardware layer (DDR V2.08 @ 333MHz bootloader + clean Kernel 5.10.160 +
calibrated DTB) with the modern dArkOSen Debian 13 (Trixie, glibc 2.41) rootfs on ext4.

Works on native Linux and Windows via WSL2 + usbipd-win.
"""

from __future__ import annotations

import argparse
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Iterable, Optional

BASE_DIR = Path(__file__).resolve().parent
OVERLAY_DIR = BASE_DIR / "rootfs_overlay"

P1_START = 32768       # 16 MiB
P1_END = 1056767       # +500 MiB (BOOT FAT)
P2_START = 1056768

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
amixer -c 0 cset iface=MIXER,name='Playback Path' SPK >/dev/null 2>&1 || true
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


class Color:
    RESET = "\033[0m"
    BOLD = "\033[1m"
    GREEN = "\033[32m"
    YELLOW = "\033[33m"
    RED = "\033[31m"
    CYAN = "\033[36m"


def info(msg: str) -> None:
    print(f"{Color.CYAN}[INFO]{Color.RESET} {msg}")


def ok(msg: str) -> None:
    print(f"{Color.GREEN}[OK]{Color.RESET} {msg}")


def warn(msg: str) -> None:
    print(f"{Color.YELLOW}[WARN]{Color.RESET} {msg}")


def die(msg: str, code: int = 1) -> None:
    print(f"{Color.RED}[ERROR]{Color.RESET} {msg}", file=sys.stderr)
    sys.exit(code)


def is_wsl() -> bool:
    rel = platform.release().lower()
    return "microsoft" in rel or "wsl" in rel


def run(
    cmd: list[str],
    *,
    check: bool = True,
    input_text: Optional[str] = None,
    capture: bool = False,
    dry_run: bool = False,
) -> subprocess.CompletedProcess:
    if dry_run:
        info(f"[dry-run] {' '.join(cmd)}")
        return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")
    return subprocess.run(
        cmd,
        check=check,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )


def require_root(dry_run: bool = False) -> None:
    if dry_run:
        return
    if os.geteuid() != 0:
        die("This command must be run as root (use sudo).")


def part_path(device: str, num: int) -> str:
    if re.search(r"[0-9]$", device):
        return f"{device}p{num}"
    return f"{device}{num}"


def get_root_disk() -> Optional[str]:
    try:
        res = subprocess.run(
            ["findmnt", "-n", "-o", "SOURCE", "/"],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        src = res.stdout.strip()
        if src.startswith("/dev/"):
            pk = subprocess.run(
                ["lsblk", "-no", "PKNAME", src],
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
            )
            parent = pk.stdout.strip().splitlines()[0] if pk.stdout.strip() else ""
            if parent:
                return f"/dev/{parent}"
    except Exception:
        pass
    return None


def validate_device(device: str, *, allow_non_removable: bool = False, dry_run: bool = False) -> int:
    if dry_run and not os.path.exists(device):
        warn(f"[dry-run] Device '{device}' not present; simulating 32 GB SD card (61,071,360 sectors).")
        return 61071360

    if not os.path.exists(device):
        die(f"Block device '{device}' does not exist.")
    if "nvme" in device:
        die(f"Refusing to touch NVMe drive '{device}'.")

    root_disk = get_root_disk()
    if root_disk and os.path.realpath(device) == os.path.realpath(root_disk):
        die(f"Refusing to touch system root disk '{device}'.")

    dev_name = Path(device).name
    rem_file = Path(f"/sys/block/{dev_name}/removable")
    removable = rem_file.read_text().strip() if rem_file.exists() else "0"
    if removable != "1":
        if is_wsl() or allow_non_removable:
            warn(
                f"Device '{device}' reports removable={removable} "
                f"({'WSL2 usbipd-win detected' if is_wsl() else '--allow-non-removable passed'})."
            )
        else:
            die(
                f"Device '{device}' is not marked removable (RM=1). "
                "If you are on WSL2 or a USB adapter reporting RM=0, pass --allow-non-removable."
            )

    size_file = Path(f"/sys/block/{dev_name}/size")
    if not size_file.exists():
        die(f"Cannot read sector count from {size_file}.")
    return int(size_file.read_text().strip())


def compute_layout(disk_sectors: int, rootfs_gb: float) -> tuple[int, int, int]:
    if rootfs_gb < 8.5:
        die(f"--rootfs-gb must be at least 8.5 GB (got {rootfs_gb}).")
    p2_sectors = int(round(rootfs_gb * 1024 * 1024 * 2))  # GiB -> 512B sectors
    p2_end = P2_START + p2_sectors - 1
    p3_start = p2_end + 1
    p3_end = disk_sectors - 35
    if disk_sectors <= p3_start + 204800:
        die(
            f"Target SD card is too small ({disk_sectors * 512 / (1024**3):.2f} GiB) "
            f"for BOOT (0.5 GiB) + ROOTFS ({rootfs_gb} GiB) + EASYROMS. Use >= 16 GB."
        )
    return p2_end, p3_start, p3_end


def unmount_device_partitions(device: str, *, dry_run: bool = False) -> None:
    if dry_run:
        info(f"[dry-run] Unmounting any mounted partitions of {device}")
        return
    for n in (1, 2, 3, 4):
        p = part_path(device, n)
        if os.path.exists(p):
            subprocess.run(["umount", p], stderr=subprocess.DEVNULL, check=False)


def safe_copy_file(src: Path, dst: Path, mode: Optional[int] = None, *, dry_run: bool = False) -> bool:
    if not src.exists():
        warn(f"Optional file missing, skipping: {src}")
        return False
    if dry_run:
        info(f"[dry-run] copy {src} -> {dst}")
        return True
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    if mode is not None:
        os.chmod(dst, mode)
    return True


def safe_symlink(target: str, link_path: Path, *, dry_run: bool = False) -> None:
    if dry_run:
        info(f"[dry-run] symlink {link_path} -> {target}")
        return
    link_path.parent.mkdir(parents=True, exist_ok=True)
    if link_path.is_symlink() or link_path.exists():
        link_path.unlink()
    os.symlink(target, link_path)


def write_text(path: Path, content: str, mode: int = 0o644, *, dry_run: bool = False) -> None:
    if dry_run:
        info(f"[dry-run] write {path} ({len(content)} bytes)")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    os.chmod(path, mode)


def detect_host_timezone() -> Optional[str]:
    lt = Path("/etc/localtime")
    if lt.is_symlink():
        resolved = str(lt.resolve())
        prefix = "/usr/share/zoneinfo/"
        if resolved.startswith(prefix):
            return resolved[len(prefix):]
    tz = Path("/etc/timezone")
    if tz.exists():
        val = tz.read_text().strip()
        if val:
            return val
    return None


def patch_retroarch_cfgs(mnt_root: Path, *, dry_run: bool = False) -> None:
    def load_k36_inputs(path: Path) -> dict[str, str]:
        inputs: dict[str, str] = {}
        for line in path.read_text().splitlines():
            line = line.strip()
            if (
                line.startswith(
                    (
                        "input_player1_",
                        "input_enable_hotkey",
                        "input_exit_emulator",
                        "input_menu_toggle",
                        "input_joypad_driver",
                    )
                )
                and "=" in line
            ):
                k, v = [x.strip() for x in line.split("=", 1)]
                inputs[k] = v
        return inputs

    for sub in ("retroarch", "retroarch32"):
        k36_cfg = OVERLAY_DIR / "home/ark/.config" / sub / "retroarch.cfg.k36"
        target_cfg = mnt_root / "home/ark/.config" / sub / "retroarch.cfg"
        if dry_run:
            info(f"[dry-run] patch {target_cfg} with {k36_cfg}")
            continue
        if not target_cfg.exists():
            warn(f"RetroArch config not found, skipping: {target_cfg}")
            continue
        k36_in = load_k36_inputs(k36_cfg) if k36_cfg.exists() else {}
        k36_in["menu_swap_ok_cancel_buttons"] = '"false"'
        lines = target_cfg.read_text().splitlines(keepends=True)
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
        target_cfg.write_text("".join(out))


def apply_boot_files(mnt_boot: Path, *, experimental_ram: bool, dry_run: bool = False) -> None:
    dtb_src = BASE_DIR / ("rf3536k4ka_ram_test_666.dtb" if experimental_ram else "rf3536k4ka.dtb")
    if not dtb_src.exists():
        die(f"Required DTB not found: {dtb_src}")

    if not dry_run and (mnt_boot / "rf3536k4ka.dtb").exists():
        shutil.copy2(mnt_boot / "rf3536k4ka.dtb", mnt_boot / "rf3536k4ka.dtb.orig")

    safe_copy_file(dtb_src, mnt_boot / "rf3536k4ka.dtb", 0o644, dry_run=dry_run)
    safe_copy_file(dtb_src, mnt_boot / "rf3536k3ka.dtb", 0o644, dry_run=dry_run)

    # Optional clean kernel override if extracted locally
    if (BASE_DIR / "Image_arkos_k36").exists():
        safe_copy_file(BASE_DIR / "Image_arkos_k36", mnt_boot / "Image", 0o644, dry_run=dry_run)
    if (BASE_DIR / "uInitrd_arkos_k36").exists():
        safe_copy_file(BASE_DIR / "uInitrd_arkos_k36", mnt_boot / "uInitrd", 0o644, dry_run=dry_run)

    # dArkOSen U-Boot logos (640x480 24-bit BMP with K36 header)
    logo = BASE_DIR / "darkosen_logo_640x480.bmp"
    if logo.exists():
        safe_copy_file(logo, mnt_boot / "logo.bmp", 0o644, dry_run=dry_run)
        safe_copy_file(logo, mnt_boot / "logo_kernel.bmp", 0o644, dry_run=dry_run)
        bmps_dir = mnt_boot / "BMPs"
        if not dry_run:
            if bmps_dir.exists():
                for old in bmps_dir.glob("*.bmp"):
                    old.unlink()
            bmps_dir.mkdir(parents=True, exist_ok=True)
        safe_copy_file(logo, bmps_dir / "logo.bmp", 0o644, dry_run=dry_run)

    # Battery charging BMPs (220x110)
    bat_dir = BASE_DIR / "battery_bmps"
    if bat_dir.is_dir():
        for bfile in sorted(bat_dir.glob("battery_*.bmp")):
            safe_copy_file(bfile, mnt_boot / bfile.name, 0o644, dry_run=dry_run)

    write_text(mnt_boot / "extlinux/extlinux.conf", EXTLINUX_CONF, 0o644, dry_run=dry_run)


def apply_rootfs_patches(
    mnt_root: Path,
    *,
    timezone: Optional[str],
    full_transplant: bool,
    dry_run: bool = False,
) -> None:
    if full_transplant:
        # 1. Kernel 5.10.160 modules + revision symlinks
        mod_src = OVERLAY_DIR / "usr/lib/modules/5.10.160-gb9111f792d94-dirty"
        mod_dst_root = mnt_root / "usr/lib/modules"
        if mod_src.is_dir():
            if not dry_run:
                mod_dst_root.mkdir(parents=True, exist_ok=True)
                target_mod = mod_dst_root / mod_src.name
                if target_mod.exists():
                    shutil.rmtree(target_mod)
                shutil.copytree(mod_src, target_mod, symlinks=True)
            else:
                info(f"[dry-run] copytree {mod_src} -> {mod_dst_root / mod_src.name}")
            for kver in (
                "5.10.160-gc18be26ca0ba-dirty",
                "5.10.160-ge8de3988c23f-dirty",
                "5.10.160-g4c735a3db925-dirty",
            ):
                safe_symlink("5.10.160-gb9111f792d94-dirty", mod_dst_root / kver, dry_run=dry_run)
        else:
            warn(f"Kernel modules folder missing: {mod_src}")

        # 2. exfat-fuse binary
        if safe_copy_file(
            OVERLAY_DIR / "usr/sbin/mount.exfat-fuse",
            mnt_root / "usr/sbin/mount.exfat-fuse",
            0o755,
            dry_run=dry_run,
        ):
            safe_symlink("mount.exfat-fuse", mnt_root / "usr/sbin/mount.exfat", dry_run=dry_run)
            safe_symlink("/usr/sbin/mount.exfat-fuse", mnt_root / "sbin/mount.exfat", dry_run=dry_run)

        # 3. Hardware helper binaries and scripts from overlay
        bin_dir = OVERLAY_DIR / "usr/local/bin"
        if bin_dir.is_dir():
            for item in sorted(bin_dir.iterdir()):
                if item.is_file() and item.name != "change_time_k36.sh":
                    safe_copy_file(item, mnt_root / "usr/local/bin" / item.name, 0o755, dry_run=dry_run)
        safe_copy_file(
            OVERLAY_DIR / "usr/local/bin/zram-autostart.sh",
            mnt_root / "usr/local/bin/zram_autostart.sh",
            0o755,
            dry_run=dry_run,
        )

        # 4. Patch fn_menu_watcher.sh and mmcblk0p3 -> mmcblk1p3 scripts
        fn_watcher = mnt_root / "usr/local/bin/fn_menu_watcher.sh"
        if not dry_run and fn_watcher.exists():
            txt = fn_watcher.read_text()
            txt = txt.replace('Name="GO-Super Gamepad"', 'Name="play_joystick"')
            txt = re.sub(
                r'if \[\[ "\$LINE" == \*"BTN_TRIGGER_HAPPY5"\*.*\]; then',
                'if [[ "$LINE" == *"BTN_TRIGGER_HAPPY5"* || "$LINE" == *"KEY_FN"* || "$LINE" == *"BTN_MODE"* ]]; then',
                txt,
            )
            fn_watcher.write_text(txt)

        for sc_name in ("Scan_SD1p3.sh", "Switch to Main SD for Roms.sh"):
            sc = mnt_root / "usr/local/bin" / sc_name
            if not dry_run and sc.exists():
                sc.write_text(sc.read_text().replace("mmcblk0p3", "mmcblk1p3"))

        # 5. play_joystick configs
        safe_copy_file(
            OVERLAY_DIR / "etc/emulationstation/es_input.cfg",
            mnt_root / "etc/emulationstation/es_input.cfg",
            0o644,
            dry_run=dry_run,
        )
        safe_copy_file(
            OVERLAY_DIR / "etc/emulationstation/es_input.cfg",
            mnt_root / "home/ark/.quirks/es_input.cfg",
            0o644,
            dry_run=dry_run,
        )
        pmk36_src = OVERLAY_DIR / "home/ark/pmk36"
        if pmk36_src.is_dir() and not dry_run:
            dst_pm = mnt_root / "home/ark/pmk36"
            if dst_pm.exists():
                shutil.rmtree(dst_pm)
            shutil.copytree(pmk36_src, dst_pm)

        for gcdb in (
            mnt_root / "opt/inttools/gamecontrollerdb.txt",
            mnt_root / "usr/bin/emulationstation/resources/gamecontrollerdb.txt",
        ):
            if not dry_run and gcdb.exists():
                cur = gcdb.read_text()
                if "19000f6a706c61795f6a6f7973746900" not in cur:
                    gcdb.write_text(cur.rstrip("\n") + "\n" + PJ_GCDB_LINE + "\n")

        # 6. Safe RAM / CPU clocks, fstab, ZRam 512MB lz4, hp_autoswitch
        write_text(mnt_root / "etc/dmc-settings.conf", "FREQ=328000000\n", 0o644, dry_run=dry_run)
        write_text(mnt_root / "etc/cpu-settings.conf", "GOV=ondemand\nFREQ=1296000\n", 0o644, dry_run=dry_run)
        write_text(mnt_root / "etc/fstab", FSTAB_CONTENT, 0o644, dry_run=dry_run)
        write_text(mnt_root / "etc/zram.conf", ZRAM_CONF, 0o644, dry_run=dry_run)

        if safe_copy_file(
            OVERLAY_DIR / "etc/systemd/system/hp_autoswitch.service",
            mnt_root / "etc/systemd/system/hp_autoswitch.service",
            0o644,
            dry_run=dry_run,
        ):
            safe_symlink(
                "/etc/systemd/system/hp_autoswitch.service",
                mnt_root / "etc/systemd/system/multi-user.target.wants/hp_autoswitch.service",
                dry_run=dry_run,
            )

        if not dry_run:
            for ob in (
                mnt_root / "etc/systemd/system/multi-user.target.wants/zram-swap.service",
                mnt_root / "etc/systemd/system/swap.target.wants/zram-swap.service",
                mnt_root / "etc/systemd/system/zram-swap.service",
                mnt_root / "etc/systemd/system/multi-user.target.wants/firstboot.service",
            ):
                if ob.is_symlink() or ob.exists():
                    ob.unlink()

        safe_symlink("/roms/themes", mnt_root / "home/ark/.emulationstation/themes", dry_run=dry_run)
        safe_symlink("/roms/themes", mnt_root / "etc/emulationstation/themes", dry_run=dry_run)

    # Always applied (both build & patch):
    # Mali UK 11.38 symlinks
    safe_symlink(
        "libmali-bifrost-g31-rxp0-gbm.so",
        mnt_root / "usr/lib/aarch64-linux-gnu/libMali.so",
        dry_run=dry_run,
    )
    safe_symlink(
        "libmali-bifrost-g31-rxp0-gbm.so",
        mnt_root / "usr/lib/arm-linux-gnueabihf/libMali.so",
        dry_run=dry_run,
    )

    # libfuse.so.2 for Debian 13 exFAT mount
    if safe_copy_file(
        OVERLAY_DIR / "usr/lib/aarch64-linux-gnu/libfuse.so.2.9.9",
        mnt_root / "usr/lib/aarch64-linux-gnu/libfuse.so.2.9.9",
        0o644,
        dry_run=dry_run,
    ):
        safe_symlink(
            "libfuse.so.2.9.9",
            mnt_root / "usr/lib/aarch64-linux-gnu/libfuse.so.2",
            dry_run=dry_run,
        )

    # Audio state & scripts
    safe_copy_file(OVERLAY_DIR / "etc/asound.state.k36", mnt_root / "var/local/asound.state", 0o644, dry_run=dry_run)
    safe_copy_file(
        OVERLAY_DIR / "etc/asound.state.k36",
        mnt_root / "var/lib/alsa/asound.state",
        0o644,
        dry_run=dry_run,
    )
    write_text(mnt_root / "usr/local/bin/fixvolume.sh", FIXVOLUME_SH, 0o755, dry_run=dry_run)
    write_text(mnt_root / "usr/local/bin/spktoggle.sh", SPKTOGGLE_SH, 0o755, dry_run=dry_run)

    # A/B button orientation (A = Confirm, B = Back)
    es_cfg = mnt_root / "home/ark/.emulationstation/es_settings.cfg"
    if not dry_run and es_cfg.exists():
        es_cfg.write_text(
            es_cfg.read_text().replace(
                '<bool name="InvertButtons" value="true" />',
                '<bool name="InvertButtons" value="false" />',
            )
        )
    patch_retroarch_cfgs(mnt_root, dry_run=dry_run)

    # Timezone (auto-inherit host timezone unless --timezone specified) + persistent clock
    tz = timezone or detect_host_timezone()
    if tz:
        if dry_run or (mnt_root / "usr/share/zoneinfo" / tz).exists():
            safe_symlink(f"/usr/share/zoneinfo/{tz}", mnt_root / "etc/localtime", dry_run=dry_run)
            write_text(mnt_root / "etc/timezone", f"{tz}\n", 0o644, dry_run=dry_run)
        else:
            warn(f"Timezone '{tz}' not found in target /usr/share/zoneinfo, keeping existing.")

    clock_file = mnt_root / "var/lib/systemd/timesync/clock"
    if not dry_run:
        clock_file.parent.mkdir(parents=True, exist_ok=True)
        clock_file.touch()
    write_text(mnt_root / "etc/systemd/system/save-clock.service", SAVE_CLOCK_SERVICE, 0o644, dry_run=dry_run)
    wants_dir = (
        mnt_root / "etc/systemd/system/sysinit.target.wants"
        if (mnt_root / "etc/systemd/system/sysinit.target.wants").is_dir()
        else mnt_root / "etc/systemd/system/multi-user.target.wants"
    )
    safe_symlink("/etc/systemd/system/save-clock.service", wants_dir / "save-clock.service", dry_run=dry_run)

    safe_copy_file(
        OVERLAY_DIR / "usr/local/bin/change_time_k36.sh",
        mnt_root / "opt/system/System/Change Time.sh",
        0o755,
        dry_run=dry_run,
    )

    # Cleanup duplicate temporary folders & fix /home/ark ownership
    if not dry_run:
        shutil.rmtree(mnt_root / "tempthemes", ignore_errors=True)
        if (mnt_root / "roms.tar").exists():
            (mnt_root / "roms.tar").unlink()
        if (mnt_root / "home/ark").is_dir():
            run(["chown", "-R", "1000:1000", str(mnt_root / "home/ark")], check=False)


def cmd_check(args: argparse.Namespace) -> None:
    print("==================================================================")
    print(" darkosen-k36 — Environment & Dependency Check")
    print("==================================================================")
    info(f"Platform: {platform.system()} {platform.release()} ({'WSL2' if is_wsl() else 'Native Linux'})")
    info(f"Repository dir: {BASE_DIR}")
    info(f"Detected host timezone: {detect_host_timezone() or 'unknown'}")

    required_tools = ["dd", "gdisk", "mkfs.ext4", "mkfs.exfat", "rsync", "losetup", "mount", "umount", "tar", "e2fsck", "resize2fs", "lsblk"]
    missing = []
    for t in required_tools:
        path = shutil.which(t)
        if path:
            ok(f"Tool '{t}' -> {path}")
        else:
            warn(f"Missing tool: '{t}'")
            missing.append(t)

    # Check btrfs kernel support (needed to mount dArkOSen .img p2)
    fs_txt = Path("/proc/filesystems").read_text() if Path("/proc/filesystems").exists() else ""
    if "btrfs" in fs_txt:
        ok("Kernel btrfs support: available")
    else:
        warn("btrfs not listed in /proc/filesystems (may auto-load module on mount, or install btrfs-progs)")

    # Check key repo files
    for rel in (
        "rf3536k4ka.dtb",
        "rf3536k4ka_ram_test_666.dtb",
        "darkosen_logo_640x480.bmp",
        "rootfs_overlay/usr/lib/aarch64-linux-gnu/libfuse.so.2.9.9",
        "rootfs_overlay/usr/sbin/mount.exfat-fuse",
        "rootfs_overlay/etc/asound.state.k36",
        "rootfs_overlay/usr/local/bin/change_time_k36.sh",
    ):
        p = BASE_DIR / rel
        if p.exists():
            ok(f"Asset OK: {rel}")
        else:
            warn(f"Asset missing: {rel}")

    if missing:
        print()
        warn(f"Install missing packages on Debian/Ubuntu/WSL: sudo apt install gdisk e2fsprogs exfatprogs rsync dosfstools")
        sys.exit(1)
    ok("All required tools and repository assets are ready!")


def cmd_build(args: argparse.Namespace) -> None:
    require_root(args.dry_run)
    k36_img = Path(args.k36) if args.k36 else next(iter(BASE_DIR.glob("*ArkOS*K36*.img")), None)
    darkos_img = Path(args.darkos) if args.darkos else next(iter(BASE_DIR.glob("*dArkOS*.img")), None)

    if not args.dry_run:
        if not darkos_img or not darkos_img.exists():
            die("dArkOSen .img file not found. Pass --darkos /path/to/dArkOSen.img")
        if (not k36_img or not k36_img.exists()) and not (
            (BASE_DIR / "bootloader_16M.bin").exists() and (BASE_DIR / "boot_500M.fat").exists()
        ):
            die("ArkOS K36 .img file not found. Pass --k36 /path/to/ArkOS_K36.img")

    sectors = validate_device(args.device, allow_non_removable=args.allow_non_removable, dry_run=args.dry_run)
    p2_end, p3_start, p3_end = compute_layout(sectors, args.rootfs_gb)
    easyroms_gb = (p3_end - p3_start + 1) * 512 / (1024**3)

    print("==================================================================")
    print(" darkosen-k36 — Hybrid SD Card Builder")
    print(f" Target device : {args.device} ({sectors * 512 / (1024**3):.2f} GiB)")
    print(f" Layout        : BOOT 0.5 GiB + ROOTFS {args.rootfs_gb} GiB (ext4) + EASYROMS {easyroms_gb:.2f} GiB (exFAT)")
    print(f" ArkOS K36 img : {k36_img or 'local bootloader_16M.bin + boot_500M.fat'}")
    print(f" dArkOSen img  : {darkos_img}")
    print(f" RAM DTB mode  : {'EXPERIMENTAL (328/450/528/666 MHz)' if args.experimental_ram else 'SAFE (locked 328 MHz)'}")
    print("==================================================================")

    if not args.yes and not args.dry_run:
        ans = input(f"ALL DATA ON {args.device} WILL BE ERASED. Type '{Path(args.device).name}' to continue: ").strip()
        if ans != Path(args.device).name:
            die("Aborted by user.")

    loop_dev = ""
    tmp_src = Path(tempfile.mkdtemp(prefix="darkos_src_")) if not args.dry_run else Path("/tmp/dryrun_src")
    mnt_boot = Path(tempfile.mkdtemp(prefix="darkos_boot_")) if not args.dry_run else Path("/tmp/dryrun_boot")
    mnt_root = Path(tempfile.mkdtemp(prefix="darkos_root_")) if not args.dry_run else Path("/tmp/dryrun_root")
    mnt_roms = Path(tempfile.mkdtemp(prefix="darkos_roms_")) if not args.dry_run else Path("/tmp/dryrun_roms")

    try:
        info("[1/7] Mounting dArkOSen .img (read-only) via loop device...")
        res = run(["losetup", "--show", "-f", "-P", "-r", str(darkos_img)], capture=True, dry_run=args.dry_run)
        loop_dev = res.stdout.strip() if not args.dry_run else "/dev/loop0"
        run(["mount", "-o", "ro", f"{loop_dev}p2", str(tmp_src)], dry_run=args.dry_run)

        unmount_device_partitions(args.device, dry_run=args.dry_run)

        info("[2/7] Flashing ArkOS K36 bootloader (16 MiB) + BOOT partition (500 MiB)...")
        if k36_img and k36_img.exists():
            run(["dd", f"if={k36_img}", f"of={args.device}", "bs=1M", "count=516", "conv=notrunc", "status=progress"], dry_run=args.dry_run)
        else:
            run(["dd", f"if={BASE_DIR / 'bootloader_16M.bin'}", f"of={args.device}", "bs=1M", "count=16", "conv=notrunc", "status=none"], dry_run=args.dry_run)
            run(["dd", f"if={BASE_DIR / 'boot_500M.fat'}", f"of={args.device}", "bs=1M", "seek=16", "count=500", "conv=notrunc", "status=progress"], dry_run=args.dry_run)
        run(["sync"], dry_run=args.dry_run)

        info("[3/7] Creating dynamic GPT partition table...")
        gdisk_script = f"x\ne\nm\nd\n2\nn\n2\n{P2_START}\n{p2_end}\n8300\nn\n3\n{p3_start}\n{p3_end}\n0700\nc\n1\nboot\nc\n2\nroot\nc\n3\nEASYROMS\nw\ny\ny\n"
        run(["gdisk", args.device], input_text=gdisk_script, capture=True, dry_run=args.dry_run)
        run(["blockdev", "--rereadpt", args.device], check=False, dry_run=args.dry_run)
        run(["udevadm", "settle"], check=False, dry_run=args.dry_run)
        if not args.dry_run:
            time.sleep(3)
        unmount_device_partitions(args.device, dry_run=args.dry_run)

        info("[4/7] Patching BOOT partition (calibrated DTB, extlinux.conf, dArkOSen logos)...")
        p1, p2, p3 = part_path(args.device, 1), part_path(args.device, 2), part_path(args.device, 3)
        run(["fsck.fat", "-a", p1], check=False, capture=True, dry_run=args.dry_run)
        run(["mount", p1, str(mnt_boot)], dry_run=args.dry_run)
        apply_boot_files(mnt_boot, experimental_ram=args.experimental_ram, dry_run=args.dry_run)
        run(["sync"], dry_run=args.dry_run)
        run(["umount", str(mnt_boot)], dry_run=args.dry_run)

        info("[5/7] Formatting ROOTFS (ext4) and copying dArkOSen Debian 13 (~2-4 min)...")
        run(["mkfs.ext4", "-F", "-L", "ROOTFS", "-O", "^orphan_file,^metadata_csum_seed", p2], dry_run=args.dry_run)
        run(["mount", p2, str(mnt_root)], dry_run=args.dry_run)
        run(
            [
                "rsync", "-aAX", "--info=progress2",
                "--exclude=/roms.tar", "--exclude=/tempthemes",
                "--exclude=/proc/*", "--exclude=/sys/*", "--exclude=/dev/*", "--exclude=/run/*",
                f"{tmp_src}/", f"{mnt_root}/",
            ],
            dry_run=args.dry_run,
        )
        apply_rootfs_patches(mnt_root, timezone=args.timezone, full_transplant=True, dry_run=args.dry_run)
        run(["sync"], dry_run=args.dry_run)
        run(["umount", str(mnt_root)], dry_run=args.dry_run)

        info("[6/7] Formatting EASYROMS (exFAT) and extracting roms.tar + themes + tools...")
        run(["mkfs.exfat", "-n", "EASYROMS", p3], dry_run=args.dry_run)
        run(["mount", p3, str(mnt_roms)], dry_run=args.dry_run)
        if not args.dry_run and (tmp_src / "roms.tar").exists():
            run(
                [
                    "tar", "--warning=no-timestamp", "--no-same-permissions", "--no-same-owner",
                    "--hard-dereference", "--strip-components=1", "-xf", str(tmp_src / "roms.tar"), "-C", str(mnt_roms),
                ],
                check=False,
            )
        if not args.dry_run and (tmp_src / "tempthemes").is_dir():
            (mnt_roms / "themes").mkdir(parents=True, exist_ok=True)
            run(["cp", "-rf", *[str(x) for x in (tmp_src / "tempthemes").iterdir()], str(mnt_roms / "themes")], check=False)

        safe_copy_file(BASE_DIR / "Diagnostico_Hardware_Real.sh", mnt_roms / "tools/Diagnostico_Hardware_Real.sh", 0o755, dry_run=args.dry_run)
        if args.experimental_ram:
            safe_copy_file(BASE_DIR / "Testar_RAM_Frequencia.sh", mnt_roms / "tools/Testar_RAM_Frequencia.sh", 0o755, dry_run=args.dry_run)
        for pm_sub in ("tools/PortMaster", "ports/PortMaster"):
            safe_copy_file(OVERLAY_DIR / "home/ark/pmk36/control.txt", mnt_roms / pm_sub / "control.txt", dry_run=args.dry_run)
            safe_copy_file(OVERLAY_DIR / "home/ark/pmk36/gamecontrollerdb.txt", mnt_roms / pm_sub / "gamecontrollerdb.txt", dry_run=args.dry_run)

        run(["sync"], dry_run=args.dry_run)
        run(["umount", str(mnt_roms)], dry_run=args.dry_run)

        info("[7/7] Finalizing buffers...")
        run(["sync"], dry_run=args.dry_run)
        ok(f"SUCCESS! Hybrid darkosen-k36 SD card ({args.device}) is ready.")
    finally:
        if not args.dry_run:
            for m in (mnt_boot, mnt_root, mnt_roms, tmp_src):
                subprocess.run(["umount", str(m)], stderr=subprocess.DEVNULL, check=False)
                if m.exists():
                    shutil.rmtree(m, ignore_errors=True)
            if loop_dev:
                subprocess.run(["losetup", "-d", loop_dev], stderr=subprocess.DEVNULL, check=False)


def cmd_patch(args: argparse.Namespace) -> None:
    require_root(args.dry_run)
    validate_device(args.device, allow_non_removable=args.allow_non_removable, dry_run=args.dry_run)

    # Clear stale udev inhibit rule if present
    inhibit = Path("/run/udev/rules.d/90-udisks-inhibit.rules")
    if not args.dry_run and inhibit.exists():
        inhibit.unlink()
        run(["udevadm", "control", "--reload-rules"], check=False)
        run(["udevadm", "trigger", "--subsystem-match=block"], check=False)

    unmount_device_partitions(args.device, dry_run=args.dry_run)
    p1, p2 = part_path(args.device, 1), part_path(args.device, 2)
    mnt_boot = Path(tempfile.mkdtemp(prefix="darkos_boot_")) if not args.dry_run else Path("/tmp/dryrun_boot")
    mnt_root = Path(tempfile.mkdtemp(prefix="darkos_root_")) if not args.dry_run else Path("/tmp/dryrun_root")

    try:
        info("[1/2] Updating BOOT partition (clean kernel, calibrated DTB, dArkOSen logos)...")
        run(["mount", p1, str(mnt_boot)], dry_run=args.dry_run)
        apply_boot_files(mnt_boot, experimental_ram=args.experimental_ram, dry_run=args.dry_run)
        run(["sync"], dry_run=args.dry_run)
        run(["umount", str(mnt_boot)], dry_run=args.dry_run)

        info("[2/2] Updating ROOTFS partition (Mali UK 11.38, libfuse2, audio, A/B fix, clock)...")
        run(["mount", p2, str(mnt_root)], dry_run=args.dry_run)
        apply_rootfs_patches(mnt_root, timezone=args.timezone, full_transplant=False, dry_run=args.dry_run)
        run(["sync"], dry_run=args.dry_run)
        run(["umount", str(mnt_root)], dry_run=args.dry_run)
        ok(f"PATCH COMPLETE on {args.device}!")
    finally:
        if not args.dry_run:
            for m in (mnt_boot, mnt_root):
                subprocess.run(["umount", str(m)], stderr=subprocess.DEVNULL, check=False)
                if m.exists():
                    shutil.rmtree(m, ignore_errors=True)


def cmd_ram_mode(args: argparse.Namespace) -> None:
    require_root(args.dry_run)
    validate_device(args.device, allow_non_removable=args.allow_non_removable, dry_run=args.dry_run)
    unmount_device_partitions(args.device, dry_run=args.dry_run)

    experimental = args.mode == "experimental"
    dtb_src = BASE_DIR / ("rf3536k4ka_ram_test_666.dtb" if experimental else "rf3536k4ka.dtb")
    if not dtb_src.exists():
        die(f"DTB file not found: {dtb_src}")

    p1, p3 = part_path(args.device, 1), part_path(args.device, 3)
    mnt_boot = Path(tempfile.mkdtemp(prefix="darkos_boot_")) if not args.dry_run else Path("/tmp/dryrun_boot")
    mnt_roms = Path(tempfile.mkdtemp(prefix="darkos_roms_")) if not args.dry_run else Path("/tmp/dryrun_roms")
    try:
        info(f"[1/2] Installing {'EXPERIMENTAL (328/450/528/666 MHz)' if experimental else 'SAFE (locked 328 MHz)'} DTB to {p1}...")
        run(["mount", p1, str(mnt_boot)], dry_run=args.dry_run)
        safe_copy_file(dtb_src, mnt_boot / "rf3536k4ka.dtb", 0o644, dry_run=args.dry_run)
        safe_copy_file(dtb_src, mnt_boot / "rf3536k3ka.dtb", 0o644, dry_run=args.dry_run)
        run(["sync"], dry_run=args.dry_run)
        run(["umount", str(mnt_boot)], dry_run=args.dry_run)

        if experimental:
            info(f"[2/2] Copying Testar_RAM_Frequencia.sh to {p3}/tools/...")
            run(["mount", p3, str(mnt_roms)], dry_run=args.dry_run)
            safe_copy_file(BASE_DIR / "Testar_RAM_Frequencia.sh", mnt_roms / "tools/Testar_RAM_Frequencia.sh", 0o755, dry_run=args.dry_run)
            run(["sync"], dry_run=args.dry_run)
            run(["umount", str(mnt_roms)], dry_run=args.dry_run)
        ok(f"RAM mode set to '{args.mode}' on {args.device}.")
    finally:
        if not args.dry_run:
            for m in (mnt_boot, mnt_roms):
                subprocess.run(["umount", str(m)], stderr=subprocess.DEVNULL, check=False)
                if m.exists():
                    shutil.rmtree(m, ignore_errors=True)


def cmd_resize(args: argparse.Namespace) -> None:
    require_root(args.dry_run)
    sectors = validate_device(args.device, allow_non_removable=args.allow_non_removable, dry_run=args.dry_run)
    p2_end, p3_start, p3_end = compute_layout(sectors, args.rootfs_gb)
    p2, p3 = part_path(args.device, 2), part_path(args.device, 3)

    unmount_device_partitions(args.device, dry_run=args.dry_run)
    tmp_bak = Path(tempfile.mkdtemp(prefix="easyroms_bak_")) if not args.dry_run else Path("/tmp/dryrun_bak")
    mnt_roms = Path(tempfile.mkdtemp(prefix="darkos_roms_")) if not args.dry_run else Path("/tmp/dryrun_roms")
    try:
        info("[1/5] Backing up EASYROMS contents to temporary directory...")
        run(["mount", p3, str(mnt_roms)], dry_run=args.dry_run)
        run(["rsync", "-a", "--info=progress2", f"{mnt_roms}/", f"{tmp_bak}/"], dry_run=args.dry_run)
        run(["umount", str(mnt_roms)], dry_run=args.dry_run)

        info(f"[2/5] Checking and resizing ext4 filesystem on {p2} to {args.rootfs_gb} GiB...")
        run(["e2fsck", "-f", "-y", p2], check=False, dry_run=args.dry_run)
        run(["resize2fs", p2, f"{int(args.rootfs_gb * 1000)}M"], dry_run=args.dry_run)

        info("[3/5] Updating GPT partition table...")
        gdisk_script = f"d\n3\nd\n2\nn\n2\n{P2_START}\n{p2_end}\n8300\nn\n3\n{p3_start}\n{p3_end}\n0700\nc\n2\nroot\nc\n3\nEASYROMS\nw\ny\n"
        run(["gdisk", args.device], input_text=gdisk_script, capture=True, dry_run=args.dry_run)
        run(["blockdev", "--rereadpt", args.device], check=False, dry_run=args.dry_run)
        run(["udevadm", "settle"], check=False, dry_run=args.dry_run)
        if not args.dry_run:
            time.sleep(2)
        unmount_device_partitions(args.device, dry_run=args.dry_run)

        info("[4/5] Expanding ext4 to exact partition boundary...")
        run(["e2fsck", "-f", "-y", p2], check=False, dry_run=args.dry_run)
        run(["resize2fs", p2], dry_run=args.dry_run)

        info("[5/5] Re-creating exFAT EASYROMS and restoring backed-up files...")
        run(["mkfs.exfat", "-n", "EASYROMS", p3], dry_run=args.dry_run)
        run(["mount", p3, str(mnt_roms)], dry_run=args.dry_run)
        run(["rsync", "-a", "--info=progress2", f"{tmp_bak}/", f"{mnt_roms}/"], dry_run=args.dry_run)
        run(["sync"], dry_run=args.dry_run)
        run(["umount", str(mnt_roms)], dry_run=args.dry_run)
        ok(f"RESIZE COMPLETE! ROOTFS={args.rootfs_gb} GiB, EASYROMS={(p3_end - p3_start + 1) * 512 / (1024**3):.2f} GiB.")
    finally:
        if not args.dry_run:
            subprocess.run(["umount", str(mnt_roms)], stderr=subprocess.DEVNULL, check=False)
            shutil.rmtree(mnt_roms, ignore_errors=True)
            shutil.rmtree(tmp_bak, ignore_errors=True)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="darkosen_k36.py",
        description="Unified hybrid dArkOSen (Debian 13) + ArkOS K36 (Kernel 5.10.160) SD card tool for R36S-V20 2025-05-18 (2549) / K36.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_check = sub.add_parser("check", help="Verify Linux/WSL tools, kernel btrfs support, and repository assets")
    p_check.set_defaults(func=cmd_check)

    def add_common(sp: argparse.ArgumentParser) -> None:
        sp.add_argument("-d", "--device", required=True, help="Target SD card block device (e.g. /dev/sda or /dev/sdb)")
        sp.add_argument("--allow-non-removable", action="store_true", help="Allow flashing devices where sysfs removable=0 (e.g. some USB adapters / WSL2)")
        sp.add_argument("--dry-run", action="store_true", help="Simulate all operations without modifying disks or files")

    p_build = sub.add_parser("build", help="Build and flash a hybrid SD card from scratch (supports >= 16 GB cards)")
    add_common(p_build)
    p_build.add_argument("--k36", help="Path to ArkOS_K36 .img file (auto-detected if placed in repo folder)")
    p_build.add_argument("--darkos", help="Path to dArkOSen .img file (auto-detected if placed in repo folder)")
    p_build.add_argument("--rootfs-gb", type=float, default=9.5, help="ROOTFS ext4 partition size in GiB (default: 9.5)")
    p_build.add_argument("--timezone", help="Override target timezone (e.g. UTC, America/New_York). Defaults to host timezone.")
    p_build.add_argument("--experimental-ram", action="store_true", help="Install experimental 328/450/528/666 MHz DTB + Testar_RAM_Frequencia.sh")
    p_build.add_argument("-y", "--yes", action="store_true", help="Skip interactive confirmation prompt")
    p_build.set_defaults(func=cmd_build)

    p_patch = sub.add_parser("patch", help="Apply latest kernel/DTB/audio/A-B/logos/clock patches to an existing hybrid SD card")
    add_common(p_patch)
    p_patch.add_argument("--timezone", help="Override target timezone (default: host timezone)")
    p_patch.add_argument("--experimental-ram", action="store_true", help="Use experimental 328/450/528/666 MHz DTB instead of safe 328 MHz DTB")
    p_patch.set_defaults(func=cmd_patch)

    p_ram = sub.add_parser("ram-mode", help="Switch an existing SD card between safe (328 MHz) and experimental (450/528/666 MHz) RAM DTB")
    add_common(p_ram)
    p_ram.add_argument("--mode", choices=["safe", "experimental"], required=True, help="RAM DTB profile to install")
    p_ram.set_defaults(func=cmd_ram_mode)

    p_resize = sub.add_parser("resize", help="Resize ROOTFS ext4 partition and expand EASYROMS exFAT preserving data")
    add_common(p_resize)
    p_resize.add_argument("--rootfs-gb", type=float, default=9.5, help="New ROOTFS size in GiB (default: 9.5)")
    p_resize.set_defaults(func=cmd_resize)

    return parser


def main(argv: Optional[Iterable[str]] = None) -> None:
    parser = build_parser()
    args = parser.parse_args(list(argv) if argv is not None else None)
    args.func(args)


if __name__ == "__main__":
    main()
