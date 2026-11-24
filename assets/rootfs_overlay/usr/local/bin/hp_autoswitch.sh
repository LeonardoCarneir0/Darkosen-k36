#!/bin/bash
# hp_autoswitch.sh - Roteamento automatico de audio para R36S-V20 / K36 (RK817 + USB-C DAC)
# Prioridade de saida:
#   1. Fone USB-C com DAC (snd-usb-audio: card 1, 2, ...) -> Playback Path=OFF no RK817 + .asoundrc no DAC USB
#   2. Fone P2 3.5mm (Headphone Jack=on)                  -> Playback Path=HP  no RK817 + .asoundrc no card 0
#   3. Alto-falante interno (Headphone Jack=off)          -> Playback Path=SPK no RK817 (com limitador 220/255)
# Inclui auto-recuperacao de barramento USB OTG (dwc2 ff300000.usb) contra mau contato no conector USB-C.

export LC_ALL=C
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
CARD=0
log() { echo "hp_autoswitch: $*"; }

RE_J="name='Headphone Jack'[^:]*: values=(on|off)"
RE_P="numid=([0-9]+),iface=MIXER,name='Playback Path'[^:]*: values=([0-9]+)"
RE_V="name='Playback Volume'[^:]*: values=([0-9]+),([0-9]+)"
MAX_SPK_VOL="${HPAS_MAX_SPK_VOL:-220}"

ASOUNDRC_ARK="/home/ark/.asoundrc"
ASOUNDRC_ETC="/etc/asound.conf"
ACTIVE_ASOUND_MODE=""
LAST_USB_CARD=""
LAST_USB_VOL_PCT=""
HAD_USB_DAC=0
USB_RECOVERY_TRIED=0

# Desativa autosuspend no root hub USB OTG (evita que DACs USB-C durmam e travem em silencio)
disable_usb_autosuspend() {
    local p
    for p in /sys/bus/usb/devices/usb1/power/control \
             /sys/bus/usb/devices/1-*/power/control \
             /sys/class/sound/card[1-9]*/device/../power/control; do
        [ -w "$p" ] && echo on > "$p" 2>/dev/null || true
    done
}

# Espera o mixer do RK817 (card 0) existir no boot
n=0
until amixer -c "$CARD" contents 2>/dev/null | grep -q "name='Playback Path'"; do
    n=$((n + 1)); [ "$n" -gt 120 ] && { log "mixer nao apareceu em 120 s"; exit 1; }
    sleep 1
done

# Descobre numid e indices dos itens OFF, HP e SPK no RK817 (uma vez)
CONT="$(amixer -c "$CARD" contents 2>/dev/null)"
[[ $CONT =~ $RE_P ]] && NUMID="${BASH_REMATCH[1]}"
get_item_idx() {
    local item="$1"
    printf '%s\n' "$CONT" | awk -v id="$NUMID" -v it="$item" '
        $0 ~ ("^numid=" id ",") {f=1; next}
        /^numid=/ {f=0}
        f && $0 ~ ("; Item #[0-9]+ ." it ".$") {
            n=$0; sub(/.*Item #/,"",n); sub(/ .*/,"",n); print n; exit
        }'
}
IDX_OFF="$(get_item_idx OFF)"
IDX_HP="$(get_item_idx HP)"
IDX_SPK="$(get_item_idx SPK)"
[ -z "$IDX_OFF" ] && IDX_OFF="0"

if [ -z "$NUMID" ] || [ -z "$IDX_HP" ] || [ -z "$IDX_SPK" ]; then
    log "nao identifiquei Playback Path/HP/SPK (numid='$NUMID' OFF='$IDX_OFF' HP='$IDX_HP' SPK='$IDX_SPK')"
    exit 1
fi
log "iniciado: numid=$NUMID OFF=$IDX_OFF HP=$IDX_HP SPK=$IDX_SPK (teto SPK=$MAX_SPK_VOL/255)"
disable_usb_autosuspend

# Detecta a placa de som USB-C DAC ativa (mesmo se o kernel mudar de card 1 para card 2 apos mau contato)
find_usb_card() {
    local cdir idx devpath found=""
    for cdir in /proc/asound/card[1-9]*; do
        [ -d "$cdir" ] || continue
        idx="${cdir#/proc/asound/card}"
        [[ "$idx" =~ ^[0-9]+$ ]] || continue
        # Precisa ter stream de playback (pcm0p) e device node vivo em /dev/snd
        [ -d "$cdir/pcm0p" ] || continue
        [ -e "/dev/snd/pcmC${idx}D0p" ] || continue
        [ -e "/sys/class/sound/card${idx}/device" ] || continue
        if [ -e "$cdir/usbid" ] || [ -e "$cdir/usbbus" ]; then
            found="$idx"
        else
            devpath="$(readlink -f "/sys/class/sound/card${idx}/device" 2>/dev/null || true)"
            [[ "$devpath" == *"/usb"* ]] && found="$idx"
        fi
    done
    printf '%s' "$found"
}

# Atualiza /home/ark/.asoundrc e /etc/asound.conf atomicamente apenas quando a saida muda
update_asoundrc() {
    local mode="$1" usb_card="$2" content tmp
    [ "$ACTIVE_ASOUND_MODE" = "$mode" ] && return 0

    if [ -n "$usb_card" ]; then
        content="# Gerado por hp_autoswitch.sh (MODO: USB-C DAC card ${usb_card})
pcm.!default {
    type plug
    slave.pcm {
        type hw
        card ${usb_card}
        device 0
    }
}

pcm.dmixer {
    type plug
    slave.pcm {
        type hw
        card ${usb_card}
        device 0
    }
}

ctl.!default {
    type hw
    card 0
}
"
    else
        content="# Gerado por hp_autoswitch.sh (MODO: INTERNO RK817 card 0)
pcm.!default {
    type plug
    slave.pcm \"dmixer\"
}

pcm.dmixer {
    type dmix
    ipc_key 1024
    slave {
        pcm \"hw:0,0\"
        period_time 0
        period_size 1024
        buffer_size 4096
        rate 44100
    }
    bindings {
        0 0
        1 1
    }
}

ctl.!default {
    type hw
    card 0
}
"
    fi

    for target in "$ASOUNDRC_ARK" "$ASOUNDRC_ETC"; do
        [ -d "$(dirname "$target")" ] || continue
        tmp="${target}.tmp.$$"
        if printf '%s' "$content" > "$tmp" 2>/dev/null; then
            chmod 0644 "$tmp" 2>/dev/null || true
            [ "$target" = "$ASOUNDRC_ARK" ] && chown 1000:1000 "$tmp" 2>/dev/null || true
            mv -f "$tmp" "$target" 2>/dev/null || rm -f "$tmp" 2>/dev/null
        fi
    done

    ACTIVE_ASOUND_MODE="$mode"
    log "ALSA default atualizado para: $mode"
}

# Espelha o volume do card 0 (ajustado pelos botoes fisicos Vol+/Vol- via ogage) no mixer do DAC USB-C
sync_usb_volume() {
    local usb_card="$1" rk_out="$2" vl vr pct ctrl
    if [[ $rk_out =~ $RE_V ]]; then
        vl="${BASH_REMATCH[1]}"
        vr="${BASH_REMATCH[2]}"
        [ "${vr:-0}" -gt "${vl:-0}" ] && vl="$vr"
        pct=$(( (vl * 100 + 127) / 255 ))
        [ "$pct" -lt 0 ] && pct=0
        [ "$pct" -gt 100 ] && pct=100
    else
        pct=85
    fi

    if [ "$LAST_USB_CARD" = "$usb_card" ] && [ "$LAST_USB_VOL_PCT" = "$pct" ]; then
        return 0
    fi

    while IFS= read -r ctrl; do
        [ -n "$ctrl" ] || continue
        amixer -q -c "$usb_card" sset "$ctrl" "${pct}%" unmute >/dev/null 2>&1 || \
        amixer -q -c "$usb_card" sset "$ctrl" "${pct}%" >/dev/null 2>&1 || true
    done < <(amixer -c "$usb_card" scontrols 2>/dev/null | sed -n "s/^Simple mixer control '\([^']*\)'.*/\1/p" | grep -E -i "^(PCM|Headphone|Speaker|Master|Playback|Digital|Headset|Earphone)")

    LAST_USB_CARD="$usb_card"
    LAST_USB_VOL_PCT="$pct"
}

# Auto-recuperacao do barramento USB-C OTG apos mau contato / erro de enumeracao (-71 / -110)
recover_usb_otg() {
    log "tentando auto-recuperacao da porta USB-C OTG apos queda/mau contato..."
    # Garante que o GPIO 68 (GPIO2_PA4 = otg-gpio 5V VBUS) continue ativo se exportado
    if [ -w /sys/class/gpio/gpio68/value ]; then
        echo 1 > /sys/class/gpio/gpio68/value 2>/dev/null || true
    fi
    # Pulsa re-autorizacao do dispositivo/hub USB OTG para destravar o DAC sem reiniciar o console
    if [ -w /sys/bus/usb/devices/1-1/authorized ]; then
        echo 0 > /sys/bus/usb/devices/1-1/authorized 2>/dev/null || true
        sleep 0.2
        echo 1 > /sys/bus/usb/devices/1-1/authorized 2>/dev/null || true
    elif [ -w /sys/bus/usb/devices/usb1/authorized ]; then
        echo 0 > /sys/bus/usb/devices/usb1/authorized 2>/dev/null || true
        sleep 0.2
        echo 1 > /sys/bus/usb/devices/usb1/authorized 2>/dev/null || true
    fi
    disable_usb_autosuspend
}

apply() {
    local out j p want name usb_card
    out="$(amixer -c "$CARD" contents 2>/dev/null)" || return 1
    [[ $out =~ $RE_J ]] && j="${BASH_REMATCH[1]}" || j="off"
    [[ $out =~ $RE_P ]] && p="${BASH_REMATCH[2]}" || return 1

    usb_card="$(find_usb_card)"

    # Caso 1: Fone USB-C com DAC conectado
    if [ -n "$usb_card" ]; then
        HAD_USB_DAC=1
        USB_RECOVERY_TRIED=0
        disable_usb_autosuspend
        update_asoundrc "usb:${usb_card}" "$usb_card"

        # Desliga o alto-falante interno e a saida P2 do RK817 (Playback Path -> OFF)
        if [ "$p" != "$IDX_OFF" ]; then
            if amixer -q -c "$CARD" cset numid="$NUMID" OFF >/dev/null 2>&1; then
                log "USB-C DAC ativo (card $usb_card): RK817 Playback Path $p -> OFF"
            fi
        fi
        sync_usb_volume "$usb_card" "$out"
        return 0
    fi

    # Se o DAC USB-C acabou de cair, verifica se foi mau contato e tenta recuperar o barramento 1 vez
    if [ "$HAD_USB_DAC" -eq 1 ] && [ "$USB_RECOVERY_TRIED" -eq 0 ]; then
        USB_RECOVERY_TRIED=1
        sleep 0.6
        usb_card="$(find_usb_card)"
        if [ -z "$usb_card" ]; then
            recover_usb_otg
            sleep 0.8
            usb_card="$(find_usb_card)"
        fi
        if [ -n "$usb_card" ]; then
            log "USB-C DAC recuperado automaticamente no card $usb_card!"
            apply
            return $?
        fi
        log "USB-C DAC desconectado; retornando para o audio interno (RK817 card 0)"
        HAD_USB_DAC=0
        LAST_USB_CARD=""
        LAST_USB_VOL_PCT=""
    fi

    # Caso 2 e 3: Sem DAC USB-C -> Usa RK817 interno (HP P2 3.5mm ou SPK interno)
    update_asoundrc "internal:0" ""

    if [ "$j" = "on" ]; then
        want="$IDX_HP"; name="HP"
    else
        want="$IDX_SPK"; name="SPK"
    fi

    if [ "$p" != "$want" ]; then
        if amixer -q -c "$CARD" cset numid="$NUMID" "$name" >/dev/null 2>&1; then
            log "jack=$j: Playback Path $p -> $name"
        else
            log "FALHA ao ajustar Playback Path para $name"
        fi
    fi

    # Limitador de protecao do alto-falante interno (teto seguro = 220/255 = -13.1 dB)
    if [ "$name" = "SPK" ] && [[ $out =~ $RE_V ]]; then
        local vl="${BASH_REMATCH[1]}" vr="${BASH_REMATCH[2]}"
        if [ "${vl:-0}" -gt "$MAX_SPK_VOL" ] || [ "${vr:-0}" -gt "$MAX_SPK_VOL" ]; then
            amixer -q -c "$CARD" cset iface=MIXER,name='Playback Volume' "${MAX_SPK_VOL},${MAX_SPK_VOL}" >/dev/null 2>&1
            log "limitador SPK: Playback Volume ${vl},${vr} -> ${MAX_SPK_VOL},${MAX_SPK_VOL}"
        fi
    fi
}

# Dispositivo de entrada do jack P2 ("rockchip-rk817 Headset", chave SW_HEADPHONE_INSERT)
find_dev() {
    awk 'BEGIN{RS="";FS="\n"} /Name="[^"]*[Hh]eadset"/ && /B: SW=/ { for(i=1;i<=NF;i++) if ($i ~ /^H: Handlers=/) { n=split($i,a," "); for(j=1;j<=n;j++) if (a[j] ~ /^event[0-9]+$/) { print "/dev/input/" a[j]; exit } } }' /proc/bus/input/devices 2>/dev/null
}
EVDEV="${HPAS_EVDEV:-$(find_dev)}"

apply
if [ -n "$EVDEV" ] && [ -e "$EVDEV" ] && command -v evtest >/dev/null 2>&1; then
    log "modo hibrido: eventos P2 ($EVDEV) + monitoramento USB-C DAC a cada 1 s"
    while :; do
        exec 3< <(evtest "$EVDEV" 2>/dev/null)
        while :; do
            if IFS= read -r -t 1 -u 3 line; then
                case "$line" in
                    *SW_HEADPHONE_INSERT*|*SW_MICROPHONE_INSERT*)
                        sleep 0.1; apply; sleep 0.4; apply; sleep 1.0; apply ;;
                esac
            else
                rc=$?
                [ "$rc" -gt 128 ] && { apply; continue; }   # timeout (1s): checa USB-C DAC, volume e limitador SPK
                break                                        # EOF: evtest terminou
            fi
        done
        exec 3<&-
        log "evtest terminou; reiniciando em 2 s"
        sleep 2
        apply
    done
else
    log "modo verificacao a cada 1 s (evento/evtest indisponivel)"
    while :; do apply; sleep 1; done
fi
