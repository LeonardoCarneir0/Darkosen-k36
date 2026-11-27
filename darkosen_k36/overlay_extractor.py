"""
Device Tree (.dts) calibration compiler and ArkOS K36 ext4 modular asset extractor.
Replaces the legacy standalone prepare_k36_overlay.py script.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

from .config import (
    AUDIO_DIR,
    CONTROLS_DIR,
    DTB_DIR,
    KERNEL_MODULES_ARCHIVE,
    P2_START,
    SYSTEM_DIR,
)
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

    # 4. Calibrate battery table (2808 mAh) and speaker attenuation (0x23 = 35 = -13.125 dB = ALSA 220/255)
    dts = dts.replace(
        "ocv_table = <0xdac 0xdc1 0xdda 0xded 0xdfc 0xe08 0xe12 0xe1f 0xe2e 0xe49 0xe69 0xe82 0xe9f 0xec0 0xee4 0xf0d 0xf39 0xf6a 0xfa1 0xfe5 0x1054>;\n\t\t\t\tdesign_capacity = <0xb10>;\n\t\t\t\tdesign_qmax = <0xc2b>;",
        "ocv_table = <0xdac 0xdcb 0xde6 0xdfa 0xe0b 0xe1b 0xe2c 0xe41 0xe5b 0xe86 0xeb7 0xee2 0xf09 0xf2e 0xf4f 0xf76 0xfa6 0xfd3 0xff1 0x1009 0x104c>;\n\t\t\t\tdesign_capacity = <0xaf8>;\n\t\t\t\tdesign_qmax = <0xc11>;",
    )
    dts = dts.replace("spk-volume = <0x0b>;", "spk-volume = <0x23>;")
    dts = dts.replace("spk-volume = <0x03>;", "spk-volume = <0x23>;")

    # 5. Lock USB-C OTG controller (usb@ff300000) to Host mode so USB-C DACs never drop on loose contact
    dts = dts.replace('dr_mode = "otg";', 'dr_mode = "host";')

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

    for folder in (
        AUDIO_DIR,
        CONTROLS_DIR / "daemons",
        CONTROLS_DIR / "pmk36",
        CONTROLS_DIR / "retroarch",
        KERNEL_MODULES_ARCHIVE.parent,
        SYSTEM_DIR / "bin",
    ):
        folder.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="k36_mod_extract_") as tmp_dir:
        tmp_stage = Path(tmp_dir) / "lib/modules"
        tmp_stage.mkdir(parents=True, exist_ok=True)

        # Preserve custom drivers/net/usb/*.ko from existing archive if present
        if KERNEL_MODULES_ARCHIVE.exists():
            subprocess.run(
                ["tar", "-I", "zstd", "-xf", str(KERNEL_MODULES_ARCHIVE), "-C", str(tmp_stage)],
                check=True,
            )

        cmds = [
            f"rdump /lib/modules/5.10.160-gb9111f792d94-dirty {tmp_stage}",
            f"dump /home/ark/pmk36/control.txt {CONTROLS_DIR}/pmk36/control.txt",
            f"dump /home/ark/pmk36/gamecontrollerdb.txt {CONTROLS_DIR}/pmk36/gamecontrollerdb.txt",
            f"dump /usr/sbin/mount.exfat-fuse {SYSTEM_DIR}/bin/mount.exfat-fuse",
            f"dump /usr/local/bin/ogage {CONTROLS_DIR}/daemons/ogage",
            f"dump /usr/local/bin/fix_power_led {SYSTEM_DIR}/bin/fix_power_led",
            f"dump /usr/local/bin/checkbrightonboot {SYSTEM_DIR}/bin/checkbrightonboot",
            f"dump /usr/local/bin/fixvolume.sh {AUDIO_DIR}/fixvolume.sh",
            f"dump /etc/emulationstation/es_input.cfg {CONTROLS_DIR}/es_input.cfg",
            f"dump /home/ark/.config/retroarch/retroarch.cfg {CONTROLS_DIR}/retroarch/retroarch.cfg.k36",
            f"dump /home/ark/.config/retroarch32/retroarch.cfg {CONTROLS_DIR}/retroarch/retroarch32.cfg.k36",
        ]
        for c in cmds:
            subprocess.run(["/sbin/debugfs", "-R", c, img_off], check=True, stderr=subprocess.DEVNULL)

        depmod_bin = shutil.which("depmod") or "/usr/sbin/depmod"
        if Path(depmod_bin).exists():
            subprocess.run([depmod_bin, "-a", "-b", tmp_dir, "5.10.160-gb9111f792d94-dirty"], check=True)

        subprocess.run(
            f"tar -C {tmp_stage} --owner=0 --group=0 -cf - 5.10.160-gb9111f792d94-dirty "
            f"| zstd -19 -T0 -f -o {KERNEL_MODULES_ARCHIVE}",
            shell=True,
            check=True,
        )

    for exe in (
        SYSTEM_DIR / "bin/mount.exfat-fuse",
        SYSTEM_DIR / "bin/fix_power_led",
        SYSTEM_DIR / "bin/checkbrightonboot",
        CONTROLS_DIR / "daemons/ogage",
        AUDIO_DIR / "fixvolume.sh",
    ):
        os.chmod(exe, 0o755)

    ok(f"Extracted Kernel 5.10.160 modular assets from {k36_img}")
