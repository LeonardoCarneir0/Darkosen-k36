"""
High-level command handlers: environment check, full SD card build,
live SD card patching, RAM frequency mode toggle, partition resizing,
and overlay extraction.
"""

from __future__ import annotations

import argparse
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from .config import (
    DEVICE_TOOLS_DIR,
    DTB_DIR,
    REPO_ROOT,
    REQUIRED_ASSETS,
    REQUIRED_HOST_TOOLS,
    find_cached_file,
    find_cached_glob,
)
from .disk import (
    apply_gpt_table,
    clear_udev_inhibit_rule,
    compute_layout,
    part_path,
    unmount_device_partitions,
    validate_device,
)
from .overlay_extractor import calibrate_dts, extract_k36_rootfs_overlay
from .patcher import apply_boot_files, apply_rootfs_patches, populate_easyroms
from .utils import (
    detect_host_timezone,
    die,
    info,
    is_wsl,
    ok,
    require_root,
    run,
    safe_copy_file,
    warn,
)


def cmd_check(args: argparse.Namespace) -> None:
    print("==================================================================")
    print(" darkosen-k36 — Environment & Dependency Check")
    print("==================================================================")
    info(f"Platform: {platform.system()} {platform.release()} ({'WSL2' if is_wsl() else 'Native Linux'})")
    info(f"Repository dir: {REPO_ROOT}")
    info(f"Detected host timezone: {detect_host_timezone() or 'unknown'}")

    missing: list[str] = []
    for t in REQUIRED_HOST_TOOLS:
        path = shutil.which(t)
        if path:
            ok(f"Tool '{t}' -> {path}")
        else:
            warn(f"Missing tool: '{t}'")
            missing.append(t)

    fs_txt = Path("/proc/filesystems").read_text() if Path("/proc/filesystems").exists() else ""
    if "btrfs" in fs_txt:
        ok("Kernel btrfs support: available")
    else:
        warn("btrfs not listed in /proc/filesystems (may auto-load module on mount, or install btrfs-progs)")

    for asset_path in REQUIRED_ASSETS:
        rel = asset_path.relative_to(REPO_ROOT)
        if asset_path.exists():
            ok(f"Asset OK: {rel}")
        else:
            warn(f"Asset missing: {rel}")

    if missing:
        print()
        warn("Install missing packages on Debian/Ubuntu/WSL: sudo apt install gdisk e2fsprogs exfatprogs rsync dosfstools zstd")
        sys.exit(1)
    ok("All required tools and repository assets are ready!")


def cmd_build(args: argparse.Namespace) -> None:
    require_root(args.dry_run)
    k36_img = Path(args.k36) if args.k36 else find_cached_glob("*ArkOS*K36*.img")
    darkos_img = Path(args.darkos) if args.darkos else find_cached_glob("*dArkOS*.img")
    bootloader_bin = find_cached_file("bootloader_16M.bin")
    boot_fat = find_cached_file("boot_500M.fat")

    if not args.dry_run:
        if not darkos_img or not darkos_img.exists():
            die("dArkOSen .img file not found. Pass --darkos /path/to/dArkOSen.img (or place it in cache/).")
        if (not k36_img or not k36_img.exists()) and not (bootloader_bin and boot_fat):
            die("ArkOS K36 .img file not found. Pass --k36 /path/to/ArkOS_K36.img (or place it in cache/).")

    sectors = validate_device(args.device, allow_non_removable=args.allow_non_removable, dry_run=args.dry_run)
    p2_end, p3_start, p3_end = compute_layout(sectors, args.rootfs_gb)
    easyroms_gb = (p3_end - p3_start + 1) * 512 / (1024**3)

    print("==================================================================")
    print(" darkosen-k36 — Hybrid SD Card Builder")
    print(f" Target device : {args.device} ({sectors * 512 / (1024**3):.2f} GiB)")
    print(f" Layout        : BOOT 0.5 GiB + ROOTFS {args.rootfs_gb} GiB (ext4) + EASYROMS {easyroms_gb:.2f} GiB (exFAT)")
    print(f" ArkOS K36 img : {k36_img or 'cache/bootloader_16M.bin + cache/boot_500M.fat'}")
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
            run(["dd", f"if={bootloader_bin}", f"of={args.device}", "bs=1M", "count=16", "conv=notrunc", "status=none"], dry_run=args.dry_run)
            run(["dd", f"if={boot_fat}", f"of={args.device}", "bs=1M", "seek=16", "count=500", "conv=notrunc", "status=progress"], dry_run=args.dry_run)
        run(["sync"], dry_run=args.dry_run)

        info("[3/7] Creating dynamic GPT partition table...")
        apply_gpt_table(
            args.device,
            p2_end,
            p3_start,
            p3_end,
            relocate_backup_header=True,
            delete_p3_first=False,
            dry_run=args.dry_run,
        )

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
        populate_easyroms(mnt_roms, tmp_src, experimental_ram=args.experimental_ram, dry_run=args.dry_run)
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
    clear_udev_inhibit_rule(dry_run=args.dry_run)

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
    dtb_src = DTB_DIR / ("rf3536k4ka_ram_test_666.dtb" if experimental else "rf3536k4ka.dtb")
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
            safe_copy_file(
                DEVICE_TOOLS_DIR / "Testar_RAM_Frequencia.sh",
                mnt_roms / "tools/Testar_RAM_Frequencia.sh",
                0o755,
                dry_run=args.dry_run,
            )
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
        apply_gpt_table(
            args.device,
            p2_end,
            p3_start,
            p3_end,
            relocate_backup_header=False,
            delete_p3_first=True,
            dry_run=args.dry_run,
        )

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


def cmd_prepare_overlay(args: argparse.Namespace) -> None:
    dts_in = Path(args.dts) if args.dts else DTB_DIR / "rf3536k4ka_calibrated.dts"
    calibrate_dts(dts_in, DTB_DIR / "rf3536k4ka_calibrated.dts", DTB_DIR / "rf3536k4ka.dtb")
    if args.k36:
        extract_k36_rootfs_overlay(Path(args.k36))
