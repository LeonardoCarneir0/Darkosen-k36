"""
Block device validation, GPT partition layout computation, partitioning,
and partition mount management.
"""

from __future__ import annotations

import os
import re
import subprocess
import time
from pathlib import Path
from typing import Optional

from .config import P2_START
from .utils import die, info, is_wsl, run, warn


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


def validate_device(
    device: str,
    *,
    allow_non_removable: bool = False,
    dry_run: bool = False,
) -> int:
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


def clear_udev_inhibit_rule(*, dry_run: bool = False) -> None:
    inhibit = Path("/run/udev/rules.d/90-udisks-inhibit.rules")
    if not dry_run and inhibit.exists():
        inhibit.unlink()
        run(["udevadm", "control", "--reload-rules"], check=False)
        run(["udevadm", "trigger", "--subsystem-match=block"], check=False)


def apply_gpt_table(
    device: str,
    p2_end: int,
    p3_start: int,
    p3_end: int,
    *,
    relocate_backup_header: bool = True,
    delete_p3_first: bool = False,
    dry_run: bool = False,
) -> None:
    cmds: list[str] = []
    if relocate_backup_header:
        cmds.extend(["x", "e", "m"])
    if delete_p3_first:
        cmds.extend(["d", "3"])
    cmds.extend(
        [
            "d", "2",
            "n", "2", str(P2_START), str(p2_end), "8300",
            "n", "3", str(p3_start), str(p3_end), "0700",
        ]
    )
    if relocate_backup_header:
        cmds.extend(["c", "1", "boot"])
    cmds.extend(
        [
            "c", "2", "root",
            "c", "3", "EASYROMS",
            "w", "y",
        ]
    )
    if relocate_backup_header:
        cmds.append("y")
    gdisk_script = "\n".join(cmds) + "\n"
    run(["gdisk", device], input_text=gdisk_script, capture=True, dry_run=dry_run)
    run(["blockdev", "--rereadpt", device], check=False, dry_run=dry_run)
    run(["udevadm", "settle"], check=False, dry_run=dry_run)
    if not dry_run:
        time.sleep(3)
    unmount_device_partitions(device, dry_run=dry_run)
