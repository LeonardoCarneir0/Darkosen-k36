"""
Device Tree (.dts) calibration compiler and ArkOS K36 ext4 rootfs overlay extractor.
Replaces the legacy standalone prepare_k36_overlay.py script.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path

from .config import DTB_DIR, OVERLAY_DIR, P2_START
from .utils import die, ok


def calibrate_dts(source_dts: Path, out_dts: Path, out_dtb: Path) -> None:
    if not source_dts.exists():
        die(f"Source DTS file not found: {source_dts}")

    dts = source_dts.read_text()

    # 1. Lock lpddr3-params to 328 MHz (0x148)
    dts = re.sub(
        r"(lpddr3-params\s*\{[^}]*?freq_0\s*=\s*)<0x210>;(\s*freq_1\s*=\s*<0x148>;\s*freq_2\s*=\s*)<0x210>;(\s*freq_3\s*=\s*)<0x210>;",
        r"\1<0x148>;\2<0x148>;\3<0x148>;",
        dts,
        flags=re.S,
    )

    # 2. Cap system-status-freq at 328000 kHz (0x50140) and auto-min-freq at 194000 kHz (0x2f5d0)
    dts = dts.replace(
        "system-status-freq = <0x01 0x80e80 0x08 0x80e80 0x02 0x2f5d0 0x20 0x80e80 0x1000 0x80e80 0x4000 0x80e80 0x2000 0x80e80>;",
        "system-status-freq = <0x01 0x50140 0x08 0x50140 0x02 0x2f5d0 0x20 0x50140 0x1000 0x50140 0x4000 0x50140 0x2000 0x50140>;",
    )
    dts = dts.replace("auto-min-freq = <0x6ddd0>;", "auto-min-freq = <0x2f5d0>;")

    # 3. Disable 450 MHz and 528 MHz OPPs in dmc-opp-table
    for opp in ("opp-450000000", "opp-528000000"):
        dts = re.sub(
            rf"({opp}\s*\{{[^}}]*?opp-microvolt-L3\s*=\s*<0xe7ef0>;)(?!\s*status)",
            r'\1\n\t\t\tstatus = "disabled";',
            dts,
            flags=re.S,
        )

    # 4. Calibrate battery table (2808 mAh) and speaker volume (0x03)
    dts = dts.replace(
        "ocv_table = <0xdac 0xdc1 0xdda 0xded 0xdfc 0xe08 0xe12 0xe1f 0xe2e 0xe49 0xe69 0xe82 0xe9f 0xec0 0xee4 0xf0d 0xf39 0xf6a 0xfa1 0xfe5 0x1054>;\n\t\t\t\tdesign_capacity = <0xb10>;\n\t\t\t\tdesign_qmax = <0xc2b>;",
        "ocv_table = <0xdac 0xdcb 0xde6 0xdfa 0xe0b 0xe1b 0xe2c 0xe41 0xe5b 0xe86 0xeb7 0xee2 0xf09 0xf2e 0xf4f 0xf76 0xfa6 0xfd3 0xff1 0x1009 0x104c>;\n\t\t\t\tdesign_capacity = <0xaf8>;\n\t\t\t\tdesign_qmax = <0xc11>;",
    )
    dts = dts.replace("spk-volume = <0x0b>;", "spk-volume = <0x03>;")

    out_dts.parent.mkdir(parents=True, exist_ok=True)
    out_dts.write_text(dts)
    subprocess.run(
        ["dtc", "-I", "dts", "-O", "dtb", "-o", str(out_dtb), str(out_dts)],
        check=True,
        stderr=subprocess.DEVNULL,
    )
    shutil.copy2(out_dtb, DTB_DIR / "rf3536k3ka.dtb")
    ok(f"Compiled calibrated DTB: {out_dtb} ({out_dtb.stat().st_size} bytes)")


def extract_k36_rootfs_overlay(k36_img: Path) -> None:
    if not k36_img.exists():
        die(f"ArkOS K36 image not found: {k36_img}")

    offset_bytes = P2_START * 512
    img_off = f"{k36_img}?offset={offset_bytes}"

    for d in (
        "usr/lib/modules",
        "usr/lib/aarch64-linux-gnu",
        "usr/sbin",
        "usr/local/bin",
        "etc/emulationstation",
        "etc/systemd/system",
        "home/ark/pmk36",
        "home/ark/.config/retroarch",
        "home/ark/.config/retroarch32",
    ):
        (OVERLAY_DIR / d).mkdir(parents=True, exist_ok=True)

    cmds = [
        f"rdump /lib/modules/5.10.160-gb9111f792d94-dirty {OVERLAY_DIR}/usr/lib/modules",
        f"dump /home/ark/pmk36/control.txt {OVERLAY_DIR}/home/ark/pmk36/control.txt",
        f"dump /home/ark/pmk36/gamecontrollerdb.txt {OVERLAY_DIR}/home/ark/pmk36/gamecontrollerdb.txt",
        f"dump /usr/sbin/mount.exfat-fuse {OVERLAY_DIR}/usr/sbin/mount.exfat-fuse",
        f"dump /usr/local/bin/ogage {OVERLAY_DIR}/usr/local/bin/ogage",
        f"dump /usr/local/bin/fix_power_led {OVERLAY_DIR}/usr/local/bin/fix_power_led",
        f"dump /usr/local/bin/checkbrightonboot {OVERLAY_DIR}/usr/local/bin/checkbrightonboot",
        f"dump /usr/local/bin/fixvolume.sh {OVERLAY_DIR}/usr/local/bin/fixvolume.sh",
        f"dump /etc/emulationstation/es_input.cfg {OVERLAY_DIR}/etc/emulationstation/es_input.cfg",
        f"dump /home/ark/.config/retroarch/retroarch.cfg {OVERLAY_DIR}/home/ark/.config/retroarch/retroarch.cfg.k36",
        f"dump /home/ark/.config/retroarch32/retroarch.cfg {OVERLAY_DIR}/home/ark/.config/retroarch32/retroarch.cfg.k36",
    ]
    for c in cmds:
        subprocess.run(["/sbin/debugfs", "-R", c, img_off], check=True, stderr=subprocess.DEVNULL)

    os.chmod(OVERLAY_DIR / "usr/sbin/mount.exfat-fuse", 0o755)
    for b in ("ogage", "fix_power_led", "checkbrightonboot", "fixvolume.sh"):
        os.chmod(OVERLAY_DIR / "usr/local/bin" / b, 0o755)

    ok(f"Extracted Kernel 5.10.160 overlay from {k36_img} into {OVERLAY_DIR}")
