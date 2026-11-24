"""
Command-line interface parser and entrypoint for darkosen-k36.
"""

from __future__ import annotations

import argparse
from typing import Iterable, Optional

from . import __version__
from .builder import (
    cmd_build,
    cmd_check,
    cmd_patch,
    cmd_prepare_overlay,
    cmd_ram_mode,
    cmd_resize,
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="darkosen_k36.py",
        description=(
            "Unified hybrid dArkOSen (Debian 13) + ArkOS K36 (Kernel 5.10.160) "
            "SD card tool for R36S-V20 2025-05-18 (2549) / K36."
        ),
    )
    parser.add_argument("-V", "--version", action="version", version=f"darkosen-k36 {__version__}")
    sub = parser.add_subparsers(dest="command", required=True)

    p_check = sub.add_parser("check", help="Verify Linux/WSL tools, kernel btrfs support, and repository assets")
    p_check.set_defaults(func=cmd_check)

    def add_common(sp: argparse.ArgumentParser) -> None:
        sp.add_argument("-d", "--device", required=True, help="Target SD card block device (e.g. /dev/sda or /dev/sdb)")
        sp.add_argument(
            "--allow-non-removable",
            action="store_true",
            help="Allow flashing devices where sysfs removable=0 (e.g. some USB adapters / WSL2)",
        )
        sp.add_argument("--dry-run", action="store_true", help="Simulate all operations without modifying disks or files")

    p_build = sub.add_parser("build", help="Build and flash a hybrid SD card from scratch (supports >= 16 GB cards)")
    add_common(p_build)
    p_build.add_argument("--k36", help="Path to ArkOS_K36 .img file (auto-detected if placed in cache/ or repo root)")
    p_build.add_argument("--darkos", help="Path to dArkOSen .img file (auto-detected if placed in cache/ or repo root)")
    p_build.add_argument("--rootfs-gb", type=float, default=9.5, help="ROOTFS ext4 partition size in GiB (default: 9.5)")
    p_build.add_argument("--timezone", help="Override target timezone (e.g. UTC, America/New_York). Defaults to host timezone.")
    p_build.add_argument(
        "--experimental-ram",
        action="store_true",
        help="Install experimental 328/450/528/666 MHz DTB + Testar_RAM_Frequencia.sh",
    )
    p_build.add_argument("-y", "--yes", action="store_true", help="Skip interactive confirmation prompt")
    p_build.set_defaults(func=cmd_build)

    p_patch = sub.add_parser(
        "patch",
        help="Apply latest kernel/DTB/audio/A-B/logos/clock patches to an existing hybrid SD card",
    )
    add_common(p_patch)
    p_patch.add_argument("--timezone", help="Override target timezone (default: host timezone)")
    p_patch.add_argument(
        "--experimental-ram",
        action="store_true",
        help="Use experimental 328/450/528/666 MHz DTB instead of safe 328 MHz DTB",
    )
    p_patch.set_defaults(func=cmd_patch)

    p_ram = sub.add_parser(
        "ram-mode",
        help="Switch an existing SD card between safe (328 MHz) and experimental (450/528/666 MHz) RAM DTB",
    )
    add_common(p_ram)
    p_ram.add_argument("--mode", choices=["safe", "experimental"], required=True, help="RAM DTB profile to install")
    p_ram.set_defaults(func=cmd_ram_mode)

    p_resize = sub.add_parser("resize", help="Resize ROOTFS ext4 partition and expand EASYROMS exFAT preserving data")
    add_common(p_resize)
    p_resize.add_argument("--rootfs-gb", type=float, default=9.5, help="New ROOTFS size in GiB (default: 9.5)")
    p_resize.set_defaults(func=cmd_resize)

    p_prep = sub.add_parser("prepare-overlay", help="Compile calibrated DTB and optionally extract K36 rootfs overlay")
    p_prep.add_argument("--dts", help="Source DTS file to calibrate (defaults to assets/dtb/rf3536k4ka_calibrated.dts)")
    p_prep.add_argument("--k36", help="Optional ArkOS K36 .img file to extract Kernel 5.10.160 modules/binaries from")
    p_prep.set_defaults(func=cmd_prepare_overlay)

    return parser


def main(argv: Optional[Iterable[str]] = None) -> None:
    parser = build_parser()
    args = parser.parse_args(list(argv) if argv is not None else None)
    args.func(args)
