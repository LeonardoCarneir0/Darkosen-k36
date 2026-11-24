"""
Boot partition, ROOTFS overlay transplant, RetroArch controller patching,
and EASYROMS population logic.
"""

from __future__ import annotations

import re
import shutil
from pathlib import Path
from typing import Optional

from .config import (
    BATTERY_BMPS_DIR,
    DEVICE_TOOLS_DIR,
    DTB_DIR,
    EXTLINUX_CONF,
    FIXVOLUME_SH,
    FSTAB_CONTENT,
    LOGOS_DIR,
    OVERLAY_DIR,
    PJ_GCDB_LINE,
    SAVE_CLOCK_SERVICE,
    SPKTOGGLE_SH,
    ZRAM_CONF,
    find_cached_file,
)
from .utils import (
    detect_host_timezone,
    die,
    info,
    run,
    safe_copy_file,
    safe_symlink,
    warn,
    write_text,
)


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
        seen: set[str] = set()
        out: list[str] = []
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


def apply_boot_files(
    mnt_boot: Path,
    *,
    experimental_ram: bool,
    dry_run: bool = False,
) -> None:
    dtb_name = "rf3536k4ka_ram_test_666.dtb" if experimental_ram else "rf3536k4ka.dtb"
    dtb_src = DTB_DIR / dtb_name
    if not dtb_src.exists():
        die(f"Required DTB not found: {dtb_src}")

    if not dry_run and (mnt_boot / "rf3536k4ka.dtb").exists():
        shutil.copy2(mnt_boot / "rf3536k4ka.dtb", mnt_boot / "rf3536k4ka.dtb.orig")

    safe_copy_file(dtb_src, mnt_boot / "rf3536k4ka.dtb", 0o644, dry_run=dry_run)
    safe_copy_file(dtb_src, mnt_boot / "rf3536k3ka.dtb", 0o644, dry_run=dry_run)

    # Optional clean kernel override if extracted locally in cache/ or root
    img_override = find_cached_file("Image_arkos_k36")
    if img_override is not None:
        safe_copy_file(img_override, mnt_boot / "Image", 0o644, dry_run=dry_run)

    initrd_override = find_cached_file("uInitrd_arkos_k36")
    if initrd_override is not None:
        safe_copy_file(initrd_override, mnt_boot / "uInitrd", 0o644, dry_run=dry_run)

    # dArkOSen U-Boot logos (640x480 24-bit BMP with K36 header)
    logo = LOGOS_DIR / "darkosen_logo_640x480.bmp"
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
    if BATTERY_BMPS_DIR.is_dir():
        for bfile in sorted(BATTERY_BMPS_DIR.glob("battery_*.bmp")):
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
    safe_copy_file(
        OVERLAY_DIR / "usr/local/bin/hp_autoswitch.sh",
        mnt_root / "usr/local/bin/hp_autoswitch.sh",
        0o755,
        dry_run=dry_run,
    )
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


def populate_easyroms(
    mnt_roms: Path,
    tmp_src: Path,
    *,
    experimental_ram: bool,
    dry_run: bool = False,
) -> None:
    if not dry_run and (tmp_src / "roms.tar").exists():
        run(
            [
                "tar",
                "--warning=no-timestamp",
                "--no-same-permissions",
                "--no-same-owner",
                "--hard-dereference",
                "--strip-components=1",
                "-xf",
                str(tmp_src / "roms.tar"),
                "-C",
                str(mnt_roms),
            ],
            check=False,
        )
    if not dry_run and (tmp_src / "tempthemes").is_dir():
        (mnt_roms / "themes").mkdir(parents=True, exist_ok=True)
        run(
            ["cp", "-rf", *[str(x) for x in (tmp_src / "tempthemes").iterdir()], str(mnt_roms / "themes")],
            check=False,
        )

    safe_copy_file(
        DEVICE_TOOLS_DIR / "Diagnostico_Hardware_Real.sh",
        mnt_roms / "tools/Diagnostico_Hardware_Real.sh",
        0o755,
        dry_run=dry_run,
    )
    if experimental_ram:
        safe_copy_file(
            DEVICE_TOOLS_DIR / "Testar_RAM_Frequencia.sh",
            mnt_roms / "tools/Testar_RAM_Frequencia.sh",
            0o755,
            dry_run=dry_run,
        )
    for pm_sub in ("tools/PortMaster", "ports/PortMaster"):
        safe_copy_file(
            OVERLAY_DIR / "home/ark/pmk36/control.txt",
            mnt_roms / pm_sub / "control.txt",
            dry_run=dry_run,
        )
        safe_copy_file(
            OVERLAY_DIR / "home/ark/pmk36/gamecontrollerdb.txt",
            mnt_roms / pm_sub / "gamecontrollerdb.txt",
            dry_run=dry_run,
        )
