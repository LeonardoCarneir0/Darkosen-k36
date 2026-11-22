#!/usr/bin/env bash
# ==============================================================================
# montar_e_gravar_hibrido.sh
# Constrói e grava no cartão SD (/dev/sda) o sistema HÍBRIDO:
#   - Bootloader GPT 16 MB + Partição BOOT + Kernel 5.10.160 + DTB Calibrado
#     do ArkOS_K36_v2.0_08112025 (DDR V2.08 333MHz, RAM Xinyuwei 328MHz, RK3326-S)
#   - Sistema Operacional ROOTFS do dArkOS (Debian 13 Trixie, glibc 2.40, SDL2/3)
#     convertido para ext4 compatível com Kernel 5.10.160 + drivers transplantados
#     (Mali Bifrost UK 10.6 64/32-bit, play_joystick, exfat-fuse, ZRam 512MB lz4, hp_autoswitch)
# ==============================================================================
set -euo pipefail

DEV="${1:-/dev/sda}"
BASE_DIR="/home/leonardo/R36s/hibrido_darkos_k36"
OVERLAY="$BASE_DIR/rootfs_overlay"
DARKOS_IMG="$BASE_DIR/dArkOSen_R36_11112026.img"
CACHE_DIR="$BASE_DIR/darkos_rootfs_cache"
ROMS_TAR_CACHE="$BASE_DIR/roms.tar"

if [[ $EUID -ne 0 ]]; then
    echo "ERRO: Execute com sudo:"
    echo "  sudo $0 $DEV"
    exit 1
fi

# 1. Proteção de segurança contra gravação no SSD principal
if [[ "$DEV" == *nvme* ]] || [[ ! -b "$DEV" ]]; then
    echo "ABORTADO: '$DEV' não existe ou é o SSD principal do sistema!" >&2
    exit 1
fi

DEV_NAME="$(basename "$DEV")"
if [[ "$(cat "/sys/block/$DEV_NAME/removable" 2>/dev/null || echo 0)" != "1" ]]; then
    echo "ABORTADO: '$DEV' não está marcado como disco removível (RM=1)!" >&2
    exit 1
fi

echo "=================================================================="
echo " HÍBRIDO dArkOS (Debian 13 Trixie) + Base Hardware ArkOS K36 v2.0"
echo " Dispositivo alvo: $DEV ($(lsblk -dno SIZE,MODEL "$DEV" 2>/dev/null))"
echo "=================================================================="

# 2. Localizar ou montar a fonte do ROOTFS do dArkOS (Debian 13 Trixie)
SRC_ROOT=""
LOOP_DEV=""
TMP_SRC=""

cleanup_src() {
    if [[ -n "$TMP_SRC" && -d "$TMP_SRC" ]]; then
        umount "$TMP_SRC" 2>/dev/null || true
        rmdir "$TMP_SRC" 2>/dev/null || true
    fi
    if [[ -n "$LOOP_DEV" ]]; then
        losetup -d "$LOOP_DEV" 2>/dev/null || true
    fi
}
trap cleanup_src EXIT

if [[ -f "/run/media/leonardo/ROOTFS/etc/os-release" ]] && grep -q "trixie" "/run/media/leonardo/ROOTFS/etc/os-release" 2>/dev/null; then
    SRC_ROOT="/run/media/leonardo/ROOTFS"
    echo "[1/7] Usando ROOTFS do dArkOS já montado em $SRC_ROOT..."
elif [[ -f "$CACHE_DIR/etc/os-release" ]]; then
    SRC_ROOT="$CACHE_DIR"
    echo "[1/7] Usando cache do dArkOS (Debian 13 Trixie) em $SRC_ROOT..."
elif [[ -f "$DARKOS_IMG" ]]; then
    echo "[1/7] Montando imagem $DARKOS_IMG via loop para extrair o Debian 13..."
    TMP_SRC="$(mktemp -d)"
    LOOP_DEV="$(losetup --show -f -P -r "$DARKOS_IMG")"
    mount -o ro "${LOOP_DEV}p2" "$TMP_SRC"
    SRC_ROOT="$TMP_SRC"
else
    echo "ERRO: Não encontrei o ROOTFS do dArkOS em /run/media/leonardo/ROOTFS, nem em $DARKOS_IMG." >&2
    exit 1
fi

if [[ -f "$SRC_ROOT/roms.tar" && ! -f "$ROMS_TAR_CACHE" ]]; then
    echo "  -> Copiando roms.tar (353 MB) para cache no SSD ($ROMS_TAR_CACHE)..."
    cp -f "$SRC_ROOT/roms.tar" "$ROMS_TAR_CACHE"
fi

# Desmontar partições do cartão SD alvo (/dev/sda*)
for p in "${DEV}"*; do umount "$p" 2>/dev/null || true; done

# 3. Gravar os primeiros 16 MB (Bootloader GPT + DDR V2.08 + U-Boot K36 + Trust BL3X) e a partição BOOT (500 MB)
echo "[2/7] Gravando Bootloader GPT (16 MB) e partição BOOT (500 MB) do ArkOS K36 em $DEV..."
dd if="$BASE_DIR/bootloader_16M.bin" of="$DEV" bs=1M count=16 conv=notrunc status=none
dd if="$BASE_DIR/boot_500M.fat" of="$DEV" bs=1M seek=16 count=500 conv=notrunc status=progress
sync

# 4. Recriar tabela GPT ajustada ao tamanho real do cartão SD (Part 1: 500M BOOT, Part 2: 12G ROOTFS ext4, Part 3: Restante EASYROMS exFAT)
echo "[3/7] Configurando tabela de partições GPT (BOOT 500MB + ROOTFS 12GB ext4 + EASYROMS exFAT)..."
DISK_SECTORS="$(cat "/sys/block/$DEV_NAME/size")"
P1_START=32768
P1_END=1056767
P2_START=1056768
P2_END=20979711   # 9.5 GB (19.922.944 setores de 512 bytes) -> deixa ~2 GB livres no ROOTFS e dá +2.5 GB para o EASYROMS!
P3_START=20979712
P3_END=$(( DISK_SECTORS - 35 ))

gdisk "$DEV" >/dev/null <<EOF
x
e
m
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
1
boot
c
2
root
c
3
EASYROMS
w
y
y
EOF

blockdev --rereadpt "$DEV" 2>/dev/null || partprobe "$DEV" 2>/dev/null || true
udevadm settle 2>/dev/null || true
sleep 3
for p in "${DEV}"*; do umount "$p" 2>/dev/null || true; done

# 5. Injetar DTB calibrado e Kernel 5.10.160 de fábrica na partição BOOT (/dev/sda1)
echo "[4/7] Aplicando DTB calibrado (RK3326-S + RAM Xinyuwei 328MHz + Bateria 2808mAh) na partição BOOT..."
fsck.fat -a "${DEV}1" >/dev/null 2>&1 || true
MNT_BOOT="$(mktemp -d)"
mount "${DEV}1" "$MNT_BOOT"
cp -f "$MNT_BOOT/rf3536k4ka.dtb" "$MNT_BOOT/rf3536k4ka.dtb.orig" 2>/dev/null || true
install -m 644 "$BASE_DIR/rf3536k4ka.dtb" "$MNT_BOOT/rf3536k4ka.dtb"
install -m 644 "$BASE_DIR/rf3536k3ka.dtb" "$MNT_BOOT/rf3536k3ka.dtb"

# Copiar também Image e uInitrd do boot de fábrica que funciona, se disponível
WORK_BOOT="/home/leonardo/Downloads/desgraça/r36s v20 clone only working boot"
if [[ -f "$WORK_BOOT/Image" && -f "$WORK_BOOT/uInitrd" ]]; then
    install -m 644 "$WORK_BOOT/Image" "$MNT_BOOT/Image"
    install -m 644 "$WORK_BOOT/uInitrd" "$MNT_BOOT/uInitrd"
fi

cat > "$MNT_BOOT/extlinux/extlinux.conf" << 'EOF'
LABEL ArkOS
  LINUX /Image
  FDT /rf3536k4ka.dtb
  INITRD /uInitrd
  APPEND earlyprintk console=ttyFIQ0 rw root=/dev/mmcblk1p2 rootfstype=ext4 loglevel=7 init=/sbin/init rootwait rootdelay=10 fsck.repair=yes fbcon=rotate:0 quiet splash plymouth.ignore-serial-consoles consoleblank=0
EOF
sync
umount "$MNT_BOOT"
rmdir "$MNT_BOOT"

# 6. Formatar /dev/sda2 em ext4 (sem orphan_file/metadata_csum_seed para compatibilidade com e2fsck do uInitrd) e instalar dArkOS + drivers K36
echo "[5/7] Formatando ${DEV}2 em ext4 compatível com Kernel 5.10.160 e instalando dArkOS Debian 13..."
mkfs.ext4 -F -L ROOTFS -O ^orphan_file,^metadata_csum_seed "${DEV}2"
MNT_ROOT="$(mktemp -d)"
mount "${DEV}2" "$MNT_ROOT"

echo "  -> Copiando sistema Debian 13 (dArkOS) de $SRC_ROOT para ${DEV}2 (aguarde ~2-4 min)..."
rsync -aAX --info=progress2 \
    --exclude='/roms.tar' \
    --exclude='/proc/*' \
    --exclude='/sys/*' \
    --exclude='/dev/*' \
    --exclude='/run/*' \
    "$SRC_ROOT/" "$MNT_ROOT/"

echo "  -> Transplantando módulos do Kernel 5.10.160, driver Mali Bifrost UK 10.6, exfat-fuse e controles play_joystick..."
mkdir -p "$MNT_ROOT/usr/lib/modules" "$MNT_ROOT/opt/system/Tools"
cp -a "$OVERLAY/usr/lib/modules/5.10.160-gb9111f792d94-dirty" "$MNT_ROOT/usr/lib/modules/"
for kver in "5.10.160-gc18be26ca0ba-dirty" "5.10.160-ge8de3988c23f-dirty" "5.10.160-g4c735a3db925-dirty"; do
    ln -sfn "5.10.160-gb9111f792d94-dirty" "$MNT_ROOT/usr/lib/modules/$kver"
done

# Driver Mali Bifrost r18p0 (UK 10.6) 64-bit compatível com Kernel 5.10.160 (g18p0)
install -m 644 "$OVERLAY/usr/lib/aarch64-linux-gnu/libmali-bifrost-g31-rxp0-wayland-gbm.so" \
    "$MNT_ROOT/usr/lib/aarch64-linux-gnu/libmali-bifrost-g31-rxp0-wayland-gbm.so"
ln -sfn "libmali-bifrost-g31-rxp0-wayland-gbm.so" "$MNT_ROOT/usr/lib/aarch64-linux-gnu/libMali.so"

# Driver Mali 32-bit (garantir link libMali.so -> libmali-bifrost-g31-rxp0-gbm.so)
if [[ -f "$OVERLAY/usr/lib/arm-linux-gnueabihf/libmali-bifrost-g31-rxp0-gbm.so" ]]; then
    install -m 644 "$OVERLAY/usr/lib/arm-linux-gnueabihf/libmali-bifrost-g31-rxp0-gbm.so" \
        "$MNT_ROOT/usr/lib/arm-linux-gnueabihf/libmali-bifrost-g31-rxp0-gbm.so"
    ln -sfn "libmali-bifrost-g31-rxp0-gbm.so" "$MNT_ROOT/usr/lib/arm-linux-gnueabihf/libMali.so"
fi

# Suporte a montagem exFAT via FUSE (necessário pois Kernel 5.10.160 não tem CONFIG_EXFAT_FS nativo)
install -m 755 "$OVERLAY/usr/sbin/mount.exfat-fuse" "$MNT_ROOT/usr/sbin/mount.exfat-fuse"
ln -sfn "mount.exfat-fuse" "$MNT_ROOT/usr/sbin/mount.exfat"
ln -sfn "/usr/sbin/mount.exfat-fuse" "$MNT_ROOT/sbin/mount.exfat" 2>/dev/null || true

# Utilitários de hardware, monitor de botões e daemons de atalhos do K36
for bin in "$OVERLAY/usr/local/bin/"*; do
    [[ -f "$bin" ]] || continue
    bname="$(basename "$bin")"
    install -m 755 "$bin" "$MNT_ROOT/usr/local/bin/$bname"
done
# Sincronizar zram_autostart.sh (com underscore, usado pelo serviço nativo do dArkOS)
install -m 755 "$OVERLAY/usr/local/bin/zram-autostart.sh" "$MNT_ROOT/usr/local/bin/zram_autostart.sh"

# Ajustar fn_menu_watcher.sh do dArkOS para reconhecer o play_joystick e KEY_FN/BTN_MODE
if [[ -f "$MNT_ROOT/usr/local/bin/fn_menu_watcher.sh" ]]; then
    sed -i 's/Name="GO-Super Gamepad"/Name="play_joystick"/g' "$MNT_ROOT/usr/local/bin/fn_menu_watcher.sh"
    sed -i 's/\*"BTN_TRIGGER_HAPPY5"\*/\*"BTN_TRIGGER_HAPPY5"\*|\*"KEY_FN"\*|\*"BTN_MODE"\*/g' "$MNT_ROOT/usr/local/bin/fn_menu_watcher.sh"
fi

# Ajustar scripts de partição de ROMs do dArkOS de mmcblk0p3 para mmcblk1p3
for sc in "$MNT_ROOT/usr/local/bin/Scan_SD1p3.sh" "$MNT_ROOT/usr/local/bin/Switch to Main SD for Roms.sh"; do
    if [[ -f "$sc" ]]; then
        sed -i 's/mmcblk0p3/mmcblk1p3/g' "$sc"
    fi
done

# Ajustar frequência máxima da RAM (DMC) no dArkOS para 328 MHz (Xinyuwei LPDDR3)
echo "FREQ=328000000" > "$MNT_ROOT/etc/dmc-settings.conf"
echo -e "GOV=ondemand\nFREQ=1296000" > "$MNT_ROOT/etc/cpu-settings.conf"

# Mapeamento do controle play_joystick (19000f6a706c61795f6a6f7973746900)
install -m 644 "$OVERLAY/etc/emulationstation/es_input.cfg" "$MNT_ROOT/etc/emulationstation/es_input.cfg"
cp -f "$OVERLAY/etc/emulationstation/es_input.cfg" "$MNT_ROOT/home/ark/.quirks/es_input.cfg" 2>/dev/null || true
cp -a "$OVERLAY/home/ark/pmk36" "$MNT_ROOT/home/ark/"

# Adicionar play_joystick ao gamecontrollerdb.txt do sistema
PJ_LINE="19000f6a706c61795f6a6f7973746900,play_joystick,a:b0,b:b1,x:b2,y:b3,back:b8,guide:b10,start:b9,leftstick:b11,rightstick:b12,leftshoulder:b4,rightshoulder:b5,dpup:b14,dpdown:b15,dpleft:b16,dpright:b17,leftx:a0,lefty:a3,rightx:a2,righty:a1,lefttrigger:b6,righttrigger:b7,platform:Linux,"
for gcdb in "$MNT_ROOT/opt/inttools/gamecontrollerdb.txt" "$MNT_ROOT/usr/bin/emulationstation/resources/gamecontrollerdb.txt"; do
    if [[ -f "$gcdb" ]] && ! grep -q "19000f6a706c61795f6a6f7973746900" "$gcdb"; then
        echo "$PJ_LINE" >> "$gcdb"
    fi
done

# Aplicar mapeamento de botões do play_joystick nos retroarch.cfg (64-bit e 32-bit) do dArkOS
python3 - "$MNT_ROOT" "$OVERLAY" << 'PYPATCH'
import sys, os, re

mnt_root, overlay = sys.argv[1], sys.argv[2]

def load_k36_inputs(path):
    inputs = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line.startswith(("input_player1_", "input_enable_hotkey", "input_exit_emulator", "input_menu_toggle", "input_joypad_driver")) and "=" in line:
                k, v = [x.strip() for x in line.split("=", 1)]
                inputs[k] = v
    return inputs

for sub in ["retroarch", "retroarch32"]:
    k36_cfg = os.path.join(overlay, "home/ark/.config", sub, "retroarch.cfg.k36")
    target_cfg = os.path.join(mnt_root, "home/ark/.config", sub, "retroarch.cfg")
    if not os.path.exists(k36_cfg) or not os.path.exists(target_cfg):
        continue
    k36_in = load_k36_inputs(k36_cfg)
    with open(target_cfg) as f:
        lines = f.readlines()
    seen = set()
    out = []
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
    with open(target_cfg, "w") as f:
        f.writelines(out)
PYPATCH

# Configurar /etc/fstab, ZRam 512MB lz4 e hp_autoswitch
install -m 644 "$OVERLAY/etc/fstab" "$MNT_ROOT/etc/fstab"
cat > "$MNT_ROOT/etc/zram.conf" << 'EOF'
ENABLED=1
ALGORITHM=lz4
SIZE=536870912
ZRAM_SIZE_MB=512
ZRAM_ALGORITHM=lz4
EOF

install -m 644 "$OVERLAY/etc/systemd/system/hp_autoswitch.service" "$MNT_ROOT/etc/systemd/system/hp_autoswitch.service"
ln -sfn "/etc/systemd/system/hp_autoswitch.service" "$MNT_ROOT/etc/systemd/system/multi-user.target.wants/hp_autoswitch.service"

# Remover serviço duplicado zram-swap.service caso exista (mantemos zram_autostart.service nativo do dArkOS)
rm -f "$MNT_ROOT/etc/systemd/system/multi-user.target.wants/zram-swap.service" \
      "$MNT_ROOT/etc/systemd/system/swap.target.wants/zram-swap.service" \
      "$MNT_ROOT/etc/systemd/system/zram-swap.service"

# Desativar firstboot.service (pois as 3 partições já estão prontas e expandidas)
rm -f "$MNT_ROOT/etc/systemd/system/multi-user.target.wants/firstboot.service"

chown -R 1000:1000 "$MNT_ROOT/home/ark"
sync
umount "$MNT_ROOT"
rmdir "$MNT_ROOT"

# 7. Formatar /dev/sda3 (EASYROMS) em exFAT, extrair roms.tar e copiar os scripts .sh e controles do PortMaster
echo "[6/7] Formatando ${DEV}3 (EASYROMS) em exFAT e extraindo estrutura de ROMs + scripts..."
mkfs.exfat -n EASYROMS "${DEV}3"
MNT_ROMS="$(mktemp -d)"
mount "${DEV}3" "$MNT_ROMS"

if [[ -f "$ROMS_TAR_CACHE" ]]; then
    echo "  -> Extraindo roms.tar em EASYROMS..."
    tar --warning=no-timestamp --no-same-permissions --no-same-owner --hard-dereference --strip-components=1 -xf "$ROMS_TAR_CACHE" -C "$MNT_ROMS" || true
fi

mkdir -p "$MNT_ROMS/tools/PortMaster" "$MNT_ROMS/ports/PortMaster"
for sh_file in "/home/leonardo/R36s/v20 k36/Install.Full.PortMaster.sh" "/home/leonardo/R36s/v20 k36/ZRam_Manager.sh" "/home/leonardo/R36s/v20 k36/hp_autoswitch_instalar.sh" "/home/leonardo/R36s/v20 k36/Diagnostico_Hardware_Real.sh" "$BASE_DIR/Diagnostico_Hardware_Real.sh"; do
    if [[ -f "$sh_file" ]]; then
        cp -f "$sh_file" "$MNT_ROMS/tools/"
    fi
done

cp -f "$OVERLAY/home/ark/pmk36/control.txt" "$MNT_ROMS/tools/PortMaster/" 2>/dev/null || true
cp -f "$OVERLAY/home/ark/pmk36/gamecontrollerdb.txt" "$MNT_ROMS/tools/PortMaster/" 2>/dev/null || true
cp -f "$OVERLAY/home/ark/pmk36/control.txt" "$MNT_ROMS/ports/PortMaster/" 2>/dev/null || true
cp -f "$OVERLAY/home/ark/pmk36/gamecontrollerdb.txt" "$MNT_ROMS/ports/PortMaster/" 2>/dev/null || true

sync
umount "$MNT_ROMS"
rmdir "$MNT_ROMS"

echo "[7/7] Sincronizando buffers de escrita..."
sync
echo "=================================================================="
echo " CONCLUÍDO COM SUCESSO! O cartão $DEV está 100% pronto."
echo " Você já pode remover o cartão SD e ligar no seu R36S-V20."
echo "=================================================================="
