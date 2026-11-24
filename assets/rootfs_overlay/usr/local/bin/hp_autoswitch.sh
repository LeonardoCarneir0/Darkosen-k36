#!/bin/bash
# hp_autoswitch.sh - mantem 'Playback Path' coerente com o jack de fones (K36/RK817)
# fone conectado -> HP ; fone removido -> SPK. Criado por hp_autoswitch_instalar.sh
export LC_ALL=C
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
CARD=0
log() { echo "hp_autoswitch: $*"; }
RE_J="name='Headphone Jack'[^:]*: values=(on|off)"
RE_P="numid=([0-9]+),iface=MIXER,name='Playback Path'[^:]*: values=([0-9]+)"
RE_V="name='Playback Volume'[^:]*: values=([0-9]+),([0-9]+)"
MAX_SPK_VOL="${HPAS_MAX_SPK_VOL:-220}"

# espera o mixer existir (boot)
n=0
until amixer -c "$CARD" contents 2>/dev/null | grep -q "name='Playback Path'"; do
    n=$((n + 1)); [ "$n" -gt 120 ] && { log "mixer nao apareceu em 120 s"; exit 1; }
    sleep 1
done

# indices dos itens HP e SPK e numid (uma vez)
CONT="$(amixer -c "$CARD" contents 2>/dev/null)"
[[ $CONT =~ $RE_P ]] && NUMID="${BASH_REMATCH[1]}"
IDX_HP="$(printf '%s\n' "$CONT" | awk -v id="$NUMID" '$0 ~ ("^numid=" id ",") {f=1; next} /^numid=/ {f=0} f && /; Item #[0-9]+ .HP.$/ { n=$0; sub(/.*Item #/,"",n); sub(/ .*/,"",n); print n; exit }')"
IDX_SPK="$(printf '%s\n' "$CONT" | awk -v id="$NUMID" '$0 ~ ("^numid=" id ",") {f=1; next} /^numid=/ {f=0} f && /; Item #[0-9]+ .SPK.$/ { n=$0; sub(/.*Item #/,"",n); sub(/ .*/,"",n); print n; exit }')"
if [ -z "$NUMID" ] || [ -z "$IDX_HP" ] || [ -z "$IDX_SPK" ]; then
    log "nao identifiquei Playback Path/HP/SPK (numid='$NUMID' HP='$IDX_HP' SPK='$IDX_SPK')"; exit 1
fi
log "iniciado: numid=$NUMID HP=$IDX_HP SPK=$IDX_SPK"

apply() {
    local out j p want name
    out="$(amixer -c "$CARD" contents 2>/dev/null)"
    [[ $out =~ $RE_J ]] && j="${BASH_REMATCH[1]}" || return 1
    [[ $out =~ $RE_P ]] && p="${BASH_REMATCH[2]}" || return 1
    if [ "$j" = "on" ]; then want="$IDX_HP"; name="HP"; else want="$IDX_SPK"; name="SPK"; fi
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

# dispositivo de entrada do jack ("rockchip-rk817 Headset", chave SW_HEADPHONE_INSERT)
find_dev() {
    awk 'BEGIN{RS="";FS="\n"} /Name="[^"]*[Hh]eadset"/ && /B: SW=/ { for(i=1;i<=NF;i++) if ($i ~ /^H: Handlers=/) { n=split($i,a," "); for(j=1;j<=n;j++) if (a[j] ~ /^event[0-9]+$/) { print "/dev/input/" a[j]; exit } } }' /proc/bus/input/devices 2>/dev/null
}
EVDEV="${HPAS_EVDEV:-$(find_dev)}"

apply
if [ -n "$EVDEV" ] && [ -e "$EVDEV" ] && command -v evtest >/dev/null 2>&1; then
    log "modo por eventos: $EVDEV"
    while :; do
        exec 3< <(evtest "$EVDEV" 2>/dev/null)
        while :; do
            if IFS= read -r -t 5 -u 3 line; then
                case "$line" in
                    *SW_HEADPHONE_INSERT*|*SW_MICROPHONE_INSERT*)
                        sleep 0.1; apply; sleep 0.4; apply; sleep 1.0; apply ;;
                esac
            else
                rc=$?
                [ "$rc" -gt 128 ] && { apply; continue; }   # timeout: verificacao periodica
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
