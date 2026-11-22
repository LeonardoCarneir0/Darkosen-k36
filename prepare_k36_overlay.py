#!/usr/bin/env python3
import os, re, subprocess, shutil

out_dir = "/home/leonardo/R36s/hibrido_darkos_k36"
overlay = f"{out_dir}/rootfs_overlay"
os.makedirs(overlay, exist_ok=True)
scratch = "/home/leonardo/.gemini/antigravity/brain/0fb6a247-a25a-4c36-94a6-92fc40769906/scratch"
img_off = f"{scratch}/arkos_k36.img?offset=541065216"

# 1. Calibrate k36_rf3536k4ka.dts
with open(f"{scratch}/k36_rf3536k4ka.dts") as f:
    dts = f.read()

dts = re.sub(
    r"(lpddr3-params\s*\{[^}]*?freq_0\s*=\s*)<0x210>;(\s*freq_1\s*=\s*<0x148>;\s*freq_2\s*=\s*)<0x210>;(\s*freq_3\s*=\s*)<0x210>;",
    r"\1<0x148>;\2<0x148>;\3<0x148>;",
    dts,
    flags=re.S
)

dts = dts.replace(
    "system-status-freq = <0x01 0x80e80 0x08 0x80e80 0x02 0x2f5d0 0x20 0x80e80 0x1000 0x80e80 0x4000 0x80e80 0x2000 0x80e80>;",
    "system-status-freq = <0x01 0x50140 0x08 0x50140 0x02 0x2f5d0 0x20 0x50140 0x1000 0x50140 0x4000 0x50140 0x2000 0x50140>;"
)
dts = dts.replace("auto-min-freq = <0x6ddd0>;", "auto-min-freq = <0x2f5d0>;")

dts = re.sub(
    r"(opp-450000000\s*\{[^}]*?opp-microvolt-L3\s*=\s*<0xe7ef0>;)",
    r'\1\n\t\t\tstatus = "disabled";',
    dts,
    flags=re.S
)
dts = re.sub(
    r"(opp-528000000\s*\{[^}]*?opp-microvolt-L3\s*=\s*<0xe7ef0>;)",
    r'\1\n\t\t\tstatus = "disabled";',
    dts,
    flags=re.S
)

dts = dts.replace(
    "ocv_table = <0xdac 0xdc1 0xdda 0xded 0xdfc 0xe08 0xe12 0xe1f 0xe2e 0xe49 0xe69 0xe82 0xe9f 0xec0 0xee4 0xf0d 0xf39 0xf6a 0xfa1 0xfe5 0x1054>;\n\t\t\t\tdesign_capacity = <0xb10>;\n\t\t\t\tdesign_qmax = <0xc2b>;",
    "ocv_table = <0xdac 0xdcb 0xde6 0xdfa 0xe0b 0xe1b 0xe2c 0xe41 0xe5b 0xe86 0xeb7 0xee2 0xf09 0xf2e 0xf4f 0xf76 0xfa6 0xfd3 0xff1 0x1009 0x104c>;\n\t\t\t\tdesign_capacity = <0xaf8>;\n\t\t\t\tdesign_qmax = <0xc11>;"
)

cal_dts = f"{out_dir}/rf3536k4ka_calibrated.dts"
cal_dtb = f"{out_dir}/rf3536k4ka.dtb"
with open(cal_dts, "w") as f:
    f.write(dts)

subprocess.run(["dtc", "-I", "dts", "-O", "dtb", "-o", cal_dtb, cal_dts], check=True, stderr=subprocess.DEVNULL)
shutil.copy2(cal_dtb, f"{out_dir}/rf3536k3ka.dtb")
print("[OK] Calibrated DTB compiled:", os.path.getsize(cal_dtb), "bytes")

# 2. Extract files from ArkOS K36 rootfs using debugfs rdump / dump
for d in [
    "usr/lib/modules",
    "usr/lib/aarch64-linux-gnu",
    "usr/sbin",
    "usr/local/bin",
    "etc/emulationstation",
    "etc/systemd/system",
    "home/ark/pmk36",
    "home/ark/.config/retroarch",
    "home/ark/.config/retroarch32",
]:
    os.makedirs(f"{overlay}/{d}", exist_ok=True)

cmds = [
    f"rdump /lib/modules/5.10.160-gb9111f792d94-dirty {overlay}/usr/lib/modules",
    f"rdump /home/ark/pmk36 {overlay}/home/ark",
    f"dump /usr/lib/aarch64-linux-gnu/libmali-bifrost-g31-rxp0-wayland-gbm.so {overlay}/usr/lib/aarch64-linux-gnu/libmali-bifrost-g31-rxp0-wayland-gbm.so",
    f"dump /usr/sbin/mount.exfat-fuse {overlay}/usr/sbin/mount.exfat-fuse",
    f"dump /usr/local/bin/ogage {overlay}/usr/local/bin/ogage",
    f"dump /usr/local/bin/fix_power_led {overlay}/usr/local/bin/fix_power_led",
    f"dump /usr/local/bin/checkbrightonboot {overlay}/usr/local/bin/checkbrightonboot",
    f"dump /usr/local/bin/fixvolume.sh {overlay}/usr/local/bin/fixvolume.sh",
    f"dump /etc/emulationstation/es_input.cfg {overlay}/etc/emulationstation/es_input.cfg",
    f"dump /home/ark/.config/retroarch/retroarch.cfg {overlay}/home/ark/.config/retroarch/retroarch.cfg.k36",
    f"dump /home/ark/.config/retroarch32/retroarch.cfg {overlay}/home/ark/.config/retroarch32/retroarch.cfg.k36",
]
for c in cmds:
    subprocess.run(["/sbin/debugfs", "-R", c, img_off], check=True, stderr=subprocess.DEVNULL)

os.chmod(f"{overlay}/usr/sbin/mount.exfat-fuse", 0o755)
for b in ["ogage", "fix_power_led", "checkbrightonboot", "fixvolume.sh"]:
    os.chmod(f"{overlay}/usr/local/bin/{b}", 0o755)

print("[OK] Extracted all Kernel 5.10.160 modules, Mali UK 10.6 driver, exfat-fuse, ogage, and play_joystick configs!")
