# dArkOSen-K36

[🇧🇷 Leia em Português (README.pt-BR.md)](README.pt-BR.md)

Hybrid OS builder, calibrated Device Trees (`DTS`/`DTB`), and hardware overlay to run **dArkOSen (Debian GNU/Linux 13 "Trixie", `glibc 2.41`, SDL2 `2.32.10`)** on **R36S-V20 `2025-05-18` (batch `2549`) / K36** clone handhelds equipped with the **Rockchip RK3326-S** SoC and **Xinyuwei `XY6C256M32DM-H2` (768 MB real RAM @ 328 MHz)**.

---

## Why does this project exist?

Owners of the **R36S-V20 `2025-05-18` (batch `2549`) / K36** clone revision were stuck between two dead ends:

- **Modern images (dArkOSen, ArkOS, dArkOS4Clone on Kernel `4.4.189`):** Fail to boot (black screen or immediate freeze), even when using beta V20 `2025-05-18` DTBs.
- **Working stock / ArkOS K36 image (Kernel `5.10.160`):** Boots properly, but ships with an obsolete **Ubuntu 19.10 (`glibc 2.30`)** rootfs from 2019 — breaking almost all modern **PortMaster** ports and runtimes that require `glibc 2.34+` / `2.38+`.

**The solution:** Keep the proven low-level hardware layer (**`DDR V2.08 @ 333 MHz` bootloader + clean `5.10.160` kernel + calibrated DTB**) and run the full **dArkOSen Debian 13 (`glibc 2.41`)** root filesystem on top of it (`ext4`).

---

## Forensic Hardware Findings (`R36S-V20 2025-05-18 2549`)

### Reference Motherboard Photo
If you're unsure whether your clone matches this exact hardware revision, open the back shell and look for the black PCB marked **`R36S-V20 2025-05-18`** and **`HLS RoHS 2549`**, with a single **`XINYUWEI`** RAM chip next to the **`Rockchip RK3326-S`** SoC and **`RK817-5`** PMIC:

<p align="center">
  <img src="docs/r36s-v20-2025-05-18-2549-motherboard.jpg" alt="R36S-V20 2025-05-18 (Batch 2549) Reference Motherboard" width="480" />
</p>

Collected directly from hardware registers (`rockchip-otp0`, `MIDR_EL1`, `/proc/iomem`, `idbloader`, and kernel `dmesg`):

| Component | Actual Hardware Detected | System Impact |
|---|---|---|
| **SoC / CPU** | **Rockchip `RK3326-S`** (Quad Cortex-A35, OTP `52 4b 33 26`, SoC ID `33260001`) | Safe ceiling is **1296 MHz @ `1.10V`** (`vdd_arm`). Legacy Kernel 4.4 DTBs pushed `1.35V` / `1.5 GHz`. |
| **GPU** | **ARM Mali-G31 MP1 r0p0** (`0x7093`, up to `520 MHz`) | Kernel `5.10.160` uses `g18p0` (**UK 11.38**); requires matching `libMali.so` (`r13p0` / UK 11.38). |
| **RAM** | **Xinyuwei `XY6C256M32DM-H2`** — **768 MB real physical RAM** (`0x00200000`–`0x2fffffff`, ~717 MB usable) | Only stable at **194 MHz and 328 MHz**. Scaling to `450/528/666/786 MHz` freezes the board immediately. |
| **Storage** | **No eMMC, no SPI Flash** (MicroSD only) | Kernel `5.10` keeps `mmc0` reserved in DTB aliases, so TF1 MicroSD is mapped to **`/dev/mmcblk1`**. |
| **PMIC / Audio** | **Rockchip `RK817`** (chip ID `0x8170` on I2C `0-0020`) | External speaker amplifier clips at `spk-volume = <0x0b>`. Calibrated to **`spk-volume = <0x03>`**. |
| **Gamepad** | Proprietary **`zed_joystick`** → **`play_joystick`** | SDL2 GUID `19000f6a706c61795f6a6f7973746900` (instead of `GO-Super Gamepad` expected by dArkOSen). |
| **Display** | MIPI-DSI **`640×480 @ 59 Hz`** (4 lanes) | Panel init sequence matches `rf3536k4ka.dtb` / `rf3536k3ka.dtb`. |

### Why stock/beta V20 `2025-05-18` DTBs on dArkOSen fail on this board
1. **Incompatible `idbloader` (DDR blob):** Standard dArkOSen images use an MBR bootloader designed for 1 GB @ 666 MHz boards, which fails to initialize the 768 MB Xinyuwei RAM before the kernel or DTB even loads.
2. **RAM frequency above 328 MHz:** Beta V20 DTBs target 1 GB units running at 528–666 MHz; batch `2549` Xinyuwei chips crash above `328 MHz`.
3. **Kernel & Partitioning mismatch:** dArkOSen expects Kernel `4.4.189`, `btrfs`, `/dev/mmcblk0p2`, and `GO-Super Gamepad`; this board's 5.10 stack uses `ext4`, `/dev/mmcblk1p2`, and `play_joystick`.

### Factory Kernel "Fake RAM" Discovery
Binary inspection of the factory `5.10.160` `Image` (`pangjianwen@git` / `bruce@zed`) revealed that the manufacturer patched `si_meminfo` / `/proc/meminfo` to report **`+256 MB` of fake RAM** (showing **973 MB** in RetroArch) or double the value (**~1.4 GB**), causing PortMaster games to crash when allocating non-existent RAM.
- **Fix:** We use the clean **ArkOS K36 `5.10.160-gc18be26ca0ba-dirty` (`lw@git`)** kernel binary, which keeps all hardware drivers intact and accurately reports the real **~717 MB RAM** + **512 MB ZRam (`lz4`)**.

---

## Supported SD Card Sizes

The partitioning scripts automatically read the exact sector count of your target SD card (`/sys/block/<dev>/size`) and dynamically allocate all remaining space to `EASYROMS` (`exFAT`). **Any MicroSD card from 16 GB up to 512 GB+ is supported out of the box:**

| SD Card Size | `BOOT` (FAT16) | `ROOTFS` (Debian 13 `ext4`) | `EASYROMS` (`exFAT`) |
|---|---|---|---|
| **16 GB** (~14.9 GiB) | 500 MB | 9.5 GB (~2 GB free) | ~4.9 GB |
| **32 GB** (~29.1 GiB) | 500 MB | 9.5 GB (~2 GB free) | **~19.1 GB** |
| **64 GB** (~59.5 GiB) | 500 MB | 9.5 GB (~2 GB free) | **~49.5 GB** |
| **128 GB** (~119 GiB) | 500 MB | 9.5 GB (~2 GB free) | **~109 GB** |
| **256 GB+** | 500 MB | 9.5 GB (~2 GB free) | **All remaining space** |

---

## Key Fixes Applied by the Hybrid Stack

1. **Debian 13 (`glibc 2.41`) over clean Kernel `5.10.160`:** `ROOTFS` converted from `btrfs` to `ext4` (without `orphan_file`/`metadata_csum_seed` for full compatibility with `uInitrd`'s `e2fsck`) + Kernel `5.10.160` modules transplanted into `/usr/lib/modules/`.
2. **`exFAT` mounting without `Emergency Mode`:** Transplants `libfuse.so.2.9.9` (`aarch64-linux-gnu`) required by `mount.exfat-fuse` on Debian 13 (which ships only `libfuse3.so.4`), plus `nofail` flags in `/etc/fstab`.
3. **Mali-G31 GPU (`UK 11.38`) alignment:** Points both 64-bit and 32-bit `libMali.so` symlinks to `libmali-bifrost-g31-rxp0-gbm.so` (`r13p0` / **UK 11.38**), fixing `file /dev/mali0 is not of a compatible version (user 10.6, kernel 11.38)`.
4. **328 MHz RAM Lock + 512 MB ZRam (`lz4`):** Disables `opp-450000000` and `opp-528000000` in the calibrated DTB, locks `/etc/dmc-settings.conf` to `328000000`, and enables 512 MB `lz4` ZRam swap on boot.
5. **Full `play_joystick` Mapping & A/B Button Fix:** Injects the `play_joystick` GUID into EmulationStation, RetroArch 64/32-bit, system/PortMaster `gamecontrollerdb.txt`, `buttonmon.sh`, `ogage`, and `fn_menu_watcher.sh`; sets `InvertButtons = false` (`A` = Confirm, `B` = Back).
6. **Clean Audio (`RK817`) with Zero Clipping at 100%:** Sets hardware speaker gain to **`spk-volume = <0x03>;`** in the DTB, restores the authentic K36 `/var/local/asound.state` (`state.rockchiprk817`, `Playback Path = SPK`), and enables `hp_autoswitch.service` for automatic speaker/headphone switching.
7. **Persistent Clock (No RTC Battery) & Host Timezone Auto-Detection:** Inherits your PC's timezone automatically (works worldwide; you can also change timezone/date/time directly on the handheld via **Options → System → Change Time** or **Start → System Settings → Date and Time**) and installs `save-clock.service` to persist time across reboots.
8. **dArkOSen Boot & Charging Logos:** `640×480` 24-bit `logo.bmp` with exact K36 U-Boot BMP header + custom `220×110` `battery_0..5.bmp` / `battery_fail.bmp` charging icons.

---

## Repository Layout

| File / Folder | Description |
|---|---|
| `montar_e_gravar_hibrido.sh` | Builds and flashes a fresh hybrid SD card from scratch (supports any SD card >= 16 GB). |
| `corrigir_cartao.sh` | Fast (~5s) patcher for an already-flashed hybrid SD card (clean kernel, `0x03` audio DTB, A/B fix, dArkOSen logos, persistent clock). |
| `redimensionar_rootfs_9_5gb.sh` | Shrinks an existing 12 GB `ROOTFS` partition to 9.5 GB and expands `EASYROMS` across all remaining SD space without losing data. |
| `rf3536k4ka_calibrated.dts` / `.dtb` | Calibrated DTS source and compiled DTBs (`RK3326-S`, Xinyuwei `328 MHz`, `spk-volume = 0x03`). |
| `prepare_k36_overlay.py` | Helper script to calibrate the DTS and extract K36 kernel modules/binaries. |
| `Diagnostico_Hardware_Real.sh` | Forensic hardware diagnostic script to run directly on the handheld. |
| `rootfs_overlay/` | Kernel `5.10.160` modules, `libfuse.so.2.9.9`, `mount.exfat-fuse`, `asound.state.k36`, `hp_autoswitch.sh`, `change_time_k36.sh`, and `play_joystick` configs. |
| `darkosen_logo_640x480.bmp` & `battery_bmps/` | U-Boot-compatible boot splash and charging animation BMPs. |

---

## Usage

> **Warning:** Scripts refuse to write to NVMe or non-removable drives, but always double-check your SD card device with `lsblk` (e.g., `/dev/sda`). **Do not run official dArkOSen OTA updates that overwrite `/boot`**, as they will replace Kernel `5.10.160` with `4.4.189`.

### 1. Prerequisites
Download and extract the two base `.img` files anywhere on your Linux PC (you **do not** need to copy them into this repository folder):
- `ArkOS_K36_v2.0_08112025.img` (used automatically for the 16 MB `DDR V2.08` bootloader + 500 MB `BOOT` partition + clean `5.10.160` kernel)
- `dArkOSen_R36_11112026.img` (used automatically for the Debian 13 `glibc 2.41` rootfs, themes, and `roms.tar`)

### 2. Build & Flash a New SD Card in One Command (16 GB / 32 GB / 64 GB / 128 GB+)
```bash
sudo ./montar_e_gravar_hibrido.sh /dev/sda /path/to/ArkOS_K36_v2.0_08112025.img /path/to/dArkOSen_R36_11112026.img
```
*(Or place both `.img` files inside the repository folder and simply run `sudo ./montar_e_gravar_hibrido.sh /dev/sda`.)*

### 3. Apply Latest Fixes to an Existing Hybrid SD Card
```bash
sudo ./corrigir_cartao.sh /dev/sda
```

### 4. Resize an Existing 12 GB `ROOTFS` Card to 9.5 GB `ROOTFS`
```bash
sudo ./redimensionar_rootfs_9_5gb.sh /dev/sda
```

### 5. [Experimental] Unlock Higher RAM Frequencies (`450 / 528 / 666 MHz`)
By default, `darkosen-k36` keeps the Xinyuwei RAM safely locked at `328 MHz`. If you want to test whether your silicon can handle higher memory bandwidth (`450`, `528`, or `666 MHz`) after boot, enable the experimental DTB (`px30s-dmc-opp-table` + `lpddr3-params` + `auto-freq-en = 1`) and the on-device tester (`Options → Tools → Testar_RAM_Frequencia`):

```bash
# Enable experimental RAM frequencies (still boots safely at 328 MHz)
sudo ./ativar_ram_experimental.sh /dev/sda

# Revert back to locked 328 MHz DTB at any time
sudo ./ativar_ram_experimental.sh /dev/sda --revert
```
> **Note:** On the handheld, `Testar_RAM_Frequencia.sh` applies frequencies temporarily and runs a 64 MB SHA-256 integrity test. If the board freezes at a higher clock, simply reboot to return automatically to `328 MHz`.

---

## Credits & Special Thanks

- **Special thanks / Honorable mention to [`Plane-Customer3162`](https://www.reddit.com/user/Plane-Customer3162/)** for kindly providing the working stock boot files after I had lost the original SD card contents — without that dump, this reverse-engineering effort and hybrid build would not have been possible.
- **ArkOS** (`christianhaitian`), **ArkOS-K36** (`AeolusUX`), **dArkOSen**, and the **PortMaster** team for their incredible community projects.

## License

- All original build scripts, documentation, and custom assets in this repository are licensed under the **[MIT License](LICENSE)**.
- Linux Kernel `5.10.160` modules (`.ko`), Device Tree files (`.dts`/`.dtb`), and `exfat-fuse` binaries in `rootfs_overlay/` are licensed under **GPL-2.0**.
- `libfuse2` (`libfuse.so.2.9.9`) is licensed under **LGPL-2.1**.
