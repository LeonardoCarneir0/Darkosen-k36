#!/usr/bin/env bash
# ==============================================================================
# ativar_ram_experimental.sh — darkosen-k36
# EXPERIMENTAL: Installs the unlocked RAM frequency DTB (328/450/528/666 MHz)
# and the on-device Testar_RAM_Frequencia.sh tool onto an existing SD card.
# Boot still starts safely at 328 MHz; higher speeds are tested on demand.
#
# Usage:
#   sudo ./ativar_ram_experimental.sh /dev/sdX          # enable experimental DTB
#   sudo ./ativar_ram_experimental.sh /dev/sdX --revert # revert to locked 328 MHz DTB
# ==============================================================================
set -euo pipefail

DEV="${1:-/dev/sda}"
MODE="${2:-enable}"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo $0 /dev/sdX [--revert]"
    exit 1
fi

if [[ "$DEV" == *nvme* ]] || [[ ! -b "$DEV" ]]; then
    echo "ABORTED: '$DEV' is invalid or an internal NVMe drive!" >&2
    exit 1
fi

for p in "${DEV}"*; do umount "$p" 2>/dev/null || true; done

MNT_BOOT="$(mktemp -d)"
MNT_ROMS="$(mktemp -d)"
mount "${DEV}1" "$MNT_BOOT"

if [[ "$MODE" == "--revert" ]]; then
    echo "[1/2] Reverting BOOT DTB back to safe locked 328 MHz (rf3536k4ka.dtb)..."
    install -m 644 "$BASE_DIR/rf3536k4ka.dtb" "$MNT_BOOT/rf3536k4ka.dtb"
    install -m 644 "$BASE_DIR/rf3536k3ka.dtb" "$MNT_BOOT/rf3536k3ka.dtb"
    sync
    umount "$MNT_BOOT"
    rmdir "$MNT_BOOT" "$MNT_ROMS"
    echo "DONE! Reverted to safe 328 MHz DTB."
    exit 0
fi

echo "[1/2] Installing EXPERIMENTAL RAM DTB (328/450/528/666 MHz, auto-freq-en=1) to ${DEV}1..."
install -m 644 "$BASE_DIR/rf3536k4ka_ram_test_666.dtb" "$MNT_BOOT/rf3536k4ka.dtb"
install -m 644 "$BASE_DIR/rf3536k4ka_ram_test_666.dtb" "$MNT_BOOT/rf3536k3ka.dtb"
sync
umount "$MNT_BOOT"

echo "[2/2] Installing Testar_RAM_Frequencia.sh into EASYROMS/tools/ (${DEV}3)..."
if mount "${DEV}3" "$MNT_ROMS" 2>/dev/null; then
    mkdir -p "$MNT_ROMS/tools"
    install -m 755 "$BASE_DIR/Testar_RAM_Frequencia.sh" "$MNT_ROMS/tools/Testar_RAM_Frequencia.sh"
    sync
    umount "$MNT_ROMS"
fi
rmdir "$MNT_BOOT" "$MNT_ROMS"

echo "=================================================================="
echo " EXPERIMENTAL RAM TEST ENABLED!"
echo " Boot stays safe at 328 MHz. On the handheld, open:"
echo "   Options -> Tools -> Testar_RAM_Frequencia"
echo " To revert back to locked 328 MHz:"
echo "   sudo $0 $DEV --revert"
echo "=================================================================="
