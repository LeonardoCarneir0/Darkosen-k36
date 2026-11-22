#!/usr/bin/env bash
set -euo pipefail

DEV="${1:-/dev/sda}"
BASE_DIR="/home/leonardo/R36s/hibrido_darkos_k36"
OVERLAY="$BASE_DIR/rootfs_overlay"

if [[ $EUID -ne 0 ]]; then
    echo "Execute com: sudo $0 $DEV"
    exit 1
fi

echo "[1/6] Removendo trava temporária de automount do Linux (/run/udev/rules.d/90-udisks-inhibit.rules)..."
if [[ -f /run/udev/rules.d/90-udisks-inhibit.rules ]]; then
    rm -f /run/udev/rules.d/90-udisks-inhibit.rules
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger --subsystem-match=block 2>/dev/null || true
fi

for p in "${DEV}"*; do umount "$p" 2>/dev/null || true; done

MNT_BOOT="$(mktemp -d)"
MNT_ROOT="$(mktemp -d)"
mount "${DEV}1" "$MNT_BOOT"
mount "${DEV}2" "$MNT_ROOT"

echo "[2/6] Instalando Kernel limpo do ArkOS K36 (lw@git, 717MB reais), DTB calibrado (spk-volume = 0x03) e logos do dArkOSen..."
if [[ -f "$BASE_DIR/Image_arkos_k36" ]]; then
    install -m 644 "$BASE_DIR/Image_arkos_k36" "$MNT_BOOT/Image"
fi
if [[ -f "$BASE_DIR/uInitrd_arkos_k36" ]]; then
    install -m 644 "$BASE_DIR/uInitrd_arkos_k36" "$MNT_BOOT/uInitrd"
fi
install -m 644 "$BASE_DIR/rf3536k4ka.dtb" "$MNT_BOOT/rf3536k4ka.dtb"
install -m 644 "$BASE_DIR/rf3536k3ka.dtb" "$MNT_BOOT/rf3536k3ka.dtb"

if [[ -f "$BASE_DIR/darkosen_logo_640x480.bmp" ]]; then
    install -m 644 "$BASE_DIR/darkosen_logo_640x480.bmp" "$MNT_BOOT/logo.bmp"
    install -m 644 "$BASE_DIR/darkosen_logo_640x480.bmp" "$MNT_BOOT/logo_kernel.bmp"
    rm -rf "$MNT_BOOT/BMPs"/* 2>/dev/null || true
    mkdir -p "$MNT_BOOT/BMPs"
    install -m 644 "$BASE_DIR/darkosen_logo_640x480.bmp" "$MNT_BOOT/BMPs/logo.bmp"
fi
if [[ -d "$BASE_DIR/battery_bmps" ]]; then
    for bfile in "$BASE_DIR/battery_bmps"/battery_*.bmp; do
        [[ -f "$bfile" ]] && install -m 644 "$bfile" "$MNT_BOOT/$(basename "$bfile")"
    done
fi

echo "[3/6] Aplicando estado de áudio original do ArkOS K36 (asound.state + spktoggle + fixvolume)..."
if [[ -f "$OVERLAY/etc/asound.state.k36" ]]; then
    mkdir -p "$MNT_ROOT/var/local" "$MNT_ROOT/var/lib/alsa"
    install -m 644 "$OVERLAY/etc/asound.state.k36" "$MNT_ROOT/var/local/asound.state"
    install -m 644 "$OVERLAY/etc/asound.state.k36" "$MNT_ROOT/var/lib/alsa/asound.state"
fi

cat > "$MNT_ROOT/usr/local/bin/fixvolume.sh" << 'EOF'
#!/bin/bash
amixer -c 0 cset iface=MIXER,name='Playback Path' SPK >/dev/null 2>&1 || true
amixer -c 0 cset iface=MIXER,name='Speaker Switch' on >/dev/null 2>&1 || true
amixer -c 0 cset iface=MIXER,name='Playback Volume' 220,220 >/dev/null 2>&1 || true
exit 0
EOF
chmod 755 "$MNT_ROOT/usr/local/bin/fixvolume.sh"

cat > "$MNT_ROOT/usr/local/bin/spktoggle.sh" << 'EOF'
#!/bin/bash
if [ -f "/var/local/asound.state" ]; then
    /usr/sbin/alsactl restore -f /var/local/asound.state >/dev/null 2>&1 || true
fi
EOF
chmod 755 "$MNT_ROOT/usr/local/bin/spktoggle.sh"

# Remover scripts de LED obsoletos
rm -f "$MNT_ROOT/opt/system/System/Testar_e_Controlar_LED_K36.sh" \
      "$MNT_ROOT/opt/system/System/Change LED to Red.sh" \
      "$MNT_ROOT/opt/system/System/Change LED to Blue.sh" \
      "$MNT_ROOT/opt/system/Change LED to Red.sh" \
      "$MNT_ROOT/opt/system/Change LED to Blue.sh" 2>/dev/null || true

echo "[4/6] Desativando InvertButtons no EmulationStation e RetroArch (A = Confirmar, B = Voltar)..."
if [[ -f "$MNT_ROOT/home/ark/.emulationstation/es_settings.cfg" ]]; then
    sed -i 's/<bool name="InvertButtons" value="true" \/>/<bool name="InvertButtons" value="false" \/>/g' \
        "$MNT_ROOT/home/ark/.emulationstation/es_settings.cfg"
fi

for rcfg in "$MNT_ROOT/home/ark/.config/retroarch/retroarch.cfg" "$MNT_ROOT/home/ark/.config/retroarch32/retroarch.cfg"; do
    if [[ -f "$rcfg" ]]; then
        sed -i 's/menu_swap_ok_cancel_buttons = "true"/menu_swap_ok_cancel_buttons = "false"/g' "$rcfg"
    fi
done

echo "[5/6] Configurando Fuso Horário (America/Fortaleza UTC-3), sincronizando relógio com o PC e instalando Change Time.sh..."
ln -sfn "/usr/share/zoneinfo/America/Fortaleza" "$MNT_ROOT/etc/localtime"
echo "America/Fortaleza" > "$MNT_ROOT/etc/timezone"

mkdir -p "$MNT_ROOT/var/lib/systemd/timesync"
touch "$MNT_ROOT/var/lib/systemd/timesync/clock"

cat > "$MNT_ROOT/etc/systemd/system/save-clock.service" << 'EOF'
[Unit]
Description=Save and restore system clock across reboots without RTC battery
DefaultDependencies=no
Before=sysinit.target shutdown.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'if [ -f /var/lib/systemd/timesync/clock ]; then SAVED=$(stat -c %Y /var/lib/systemd/timesync/clock); NOW=$(date +%s); [ "$SAVED" -gt "$NOW" ] && date -s "@$SAVED" >/dev/null 2>&1 || true; fi'
ExecStop=/bin/touch /var/lib/systemd/timesync/clock

[Install]
WantedBy=sysinit.target
EOF
ln -sfn "/etc/systemd/system/save-clock.service" "$MNT_ROOT/etc/systemd/system/sysinit.target.wants/save-clock.service" 2>/dev/null || \
ln -sfn "/etc/systemd/system/save-clock.service" "$MNT_ROOT/etc/systemd/system/multi-user.target.wants/save-clock.service"

if [[ -f /tmp/change_time_k36.sh ]]; then
    install -m 755 /tmp/change_time_k36.sh "$MNT_ROOT/opt/system/System/Change Time.sh"
fi

echo "[6/6] Limpando pastas temporárias (/tempthemes, /roms.tar), sincronizando e montando EASYROMS..."
rm -rf "$MNT_ROOT/tempthemes" "$MNT_ROOT/roms.tar" 2>/dev/null || true
chown -R 1000:1000 "$MNT_ROOT/home/ark/.emulationstation" "$MNT_ROOT/home/ark/.config/retroarch" "$MNT_ROOT/home/ark/.config/retroarch32"
sync
umount "$MNT_BOOT"
umount "$MNT_ROOT"
rmdir "$MNT_BOOT" "$MNT_ROOT"

MNT_ROMS="$(mktemp -d)"
if mount "${DEV}3" "$MNT_ROMS" 2>/dev/null; then
    rm -f "$MNT_ROMS/tools/Testar_e_Controlar_LED_K36.sh" 2>/dev/null || true
    sync
    umount "$MNT_ROMS"
fi
rmdir "$MNT_ROMS"

sudo -u leonardo udisksctl mount -b "${DEV}3" 2>/dev/null || true

echo "=================================================================="
echo " TUDO PRONTO! Kernel Limpo, Som 0x03, Logos dArkOSen e Hora UTC-3!"
echo "=================================================================="
