#!/usr/bin/env bash
# ==============================================================================
# redimensionar_rootfs_9_5gb.sh
# Reduz a partição ROOTFS (/dev/sda2) de 12 GB para 9.5 GB (deixando ~2 GB livres
# no sistema) e aumenta a partição EASYROMS (/dev/sda3) de 16.6 GB para ~19.1 GB,
# preservando todos os arquivos de EASYROMS sem precisar regravar o sistema!
# ==============================================================================
set -euo pipefail

DEV="${1:-/dev/sda}"
DEV_NAME="$(basename "$DEV")"

if [[ $EUID -ne 0 ]]; then
    echo "Execute com: sudo $0 $DEV"
    exit 1
fi

if [[ "$DEV" == *nvme* ]] || [[ ! -b "$DEV" ]]; then
    echo "ABORTADO: Dispositivo inválido!" >&2
    exit 1
fi

for p in "${DEV}"*; do umount "$p" 2>/dev/null || true; done

echo "[1/5] Fazendo backup temporário dos arquivos da partição EASYROMS (/dev/sda3) no SSD..."
TMP_ROMS_BAK="$(mktemp -d /tmp/easyroms_bak.XXXXXX)"
MNT_ROMS="$(mktemp -d)"
if mount "${DEV}3" "$MNT_ROMS" 2>/dev/null; then
    rsync -a --info=progress2 "$MNT_ROMS/" "$TMP_ROMS_BAK/"
    umount "$MNT_ROMS"
fi
rmdir "$MNT_ROMS"

echo "[2/5] Verificando e encolhendo o sistema de arquivos ext4 de ${DEV}2 para 9.5 GB..."
e2fsck -f -y "${DEV}2" || true
resize2fs "${DEV}2" 9500M

echo "[3/5] Ajustando tabela de partições GPT (ROOTFS = 9.5 GB, EASYROMS = 19.1 GB)..."
DISK_SECTORS="$(cat "/sys/block/$DEV_NAME/size")"
P2_START=1056768
P2_END=20979711   # 9.5 GiB (19.922.944 setores)
P3_START=20979712
P3_END=$(( DISK_SECTORS - 35 ))

gdisk "$DEV" >/dev/null <<EOF
d
3
d
2
n
2
$P2_START
$P2_END
8300
n
3
$P3_START
$P3_END
0700
c
2
root
c
3
EASYROMS
w
y
EOF

blockdev --rereadpt "$DEV" 2>/dev/null || partprobe "$DEV" 2>/dev/null || true
udevadm settle 2>/dev/null || true
sleep 2
for p in "${DEV}"*; do umount "$p" 2>/dev/null || true; done

echo "[4/5] Ajustando ext4 ao tamanho exato da partição de 9.5 GB..."
e2fsck -f -y "${DEV}2" || true
resize2fs "${DEV}2"

echo "[5/5] Formatando nova partição EASYROMS de 19.1 GB em exFAT e restaurando arquivos..."
mkfs.exfat -n EASYROMS "${DEV}3"
MNT_ROMS="$(mktemp -d)"
mount "${DEV}3" "$MNT_ROMS"
rsync -a --info=progress2 "$TMP_ROMS_BAK/" "$MNT_ROMS/"
sync
umount "$MNT_ROMS"
rmdir "$MNT_ROMS"
rm -rf "$TMP_ROMS_BAK"

if [[ -n "${SUDO_USER:-}" ]]; then
    sudo -u "$SUDO_USER" udisksctl mount -b "${DEV}3" 2>/dev/null || true
fi

echo "=================================================================="
echo " CONCLUÍDO! ROOTFS reduzido para 9.5 GB (~2 GB livres) e"
echo " EASYROMS aumentado para ~19.1 GB!"
echo "=================================================================="
