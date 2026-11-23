#!/bin/bash
# ==============================================================================
# Testar_RAM_Frequencia.sh — darkosen-k36
# Testa de forma segura e gradual se a RAM Xinyuwei (768 MB) suporta
# 450 MHz, 528 MHz ou 666 MHz depois do boot (em 328 MHz).
# Se travar em alguma frequência, basta reiniciar — a alteração NÃO é permanente!
# ==============================================================================

if [ "$(id -u)" -ne 0 ]; then
    exec sudo -- "$0" "$@"
fi

export TERM=linux
CURR_TTY="/dev/tty1"
TMP_KEYS="/tmp/keys.gptk.$$"
GPTOKEYB_PID=""
DMC="/sys/class/devfreq/dmc"

Start_GPTKeyb() {
    pkill -9 -f gptokeyb 2>/dev/null || true
    sleep 0.1
    /opt/inttools/gptokeyb -1 "$0" -c "$TMP_KEYS" > /dev/null 2>&1 &
    GPTOKEYB_PID=$!
}

Stop_GPTKeyb() {
    [ -n "$GPTOKEYB_PID" ] && kill "$GPTOKEYB_PID" 2>/dev/null || true
    GPTOKEYB_PID=""
    pkill -9 -f gptokeyb 2>/dev/null || true
}

Exit_Menu() {
    trap - EXIT
    printf "\033[H\033[2J" > "$CURR_TTY"
    printf "\e[?25h" > "$CURR_TTY"
    Stop_GPTKeyb
    rm -f "$TMP_KEYS"
    exit 0
}

setfont /usr/share/consolefonts/Lat7-TerminusBold22x11.psf.gz 2>/dev/null || true
printf "\e[?25l" > "$CURR_TTY"

export SDL_GAMECONTROLLERCONFIG_FILE="/opt/inttools/gamecontrollerdb.txt"
chmod 666 /dev/uinput 2>/dev/null || true
cp /opt/inttools/keys.gptk "$TMP_KEYS" 2>/dev/null || true
if [ -f "$TMP_KEYS" ]; then
    sed -i 's/^b = .*/b = esc/' "$TMP_KEYS"
    sed -i 's/^a = .*/a = enter/' "$TMP_KEYS"
fi
Start_GPTKeyb
trap 'Exit_Menu' EXIT

test_freq() {
    local target="$1"
    local label="$2"
    dialog --backtitle "Teste de Frequencia RAM (DMC)" \
           --title "Aplicando $label" \
           --infobox "\nMudando RAM para $label...\nSe travar, reinicie (nao e permanente).\n\nRodando teste de memoria (64 MB)..." 9 52 < "$CURR_TTY" > "$CURR_TTY" 2>&1

    echo "performance" > "$DMC/governor" 2>/dev/null || true
    echo "$target" > "$DMC/max_freq" 2>/dev/null || true
    echo "$target" > "$DMC/min_freq" 2>/dev/null || true
    sleep 0.5
    local cur="$(cat "$DMC/cur_freq" 2>/dev/null || echo 0)"
    local cur_mhz=$((cur / 1000000))

    # Teste rápido de integridade de escrita/leitura de 64 MB na RAM (/dev/shm)
    dd if=/dev/urandom of=/dev/shm/ramtest.bin bs=1M count=64 status=none 2>/dev/null
    local h1="$(sha256sum /dev/shm/ramtest.bin | awk '{print $1}')"
    cp /dev/shm/ramtest.bin /dev/shm/ramtest2.bin
    local h2="$(sha256sum /dev/shm/ramtest2.bin | awk '{print $1}')"
    rm -f /dev/shm/ramtest.bin /dev/shm/ramtest2.bin

    if [ "$h1" = "$h2" ] && [ -n "$h1" ]; then
        dialog --backtitle "Teste de Frequencia RAM (DMC)" \
               --title "PASSOU!" \
               --msgbox "Frequencia real ativa: ${cur_mhz} MHz\nTeste de 64 MB SHA-256: 100% OK!\n\nA RAM agora esta rodando em ${cur_mhz} MHz.\nVoce pode sair e testar um jogo agora!\n(Ao reiniciar volta para 328 MHz.)" 12 52 < "$CURR_TTY" > "$CURR_TTY" 2>&1
    else
        echo "328000000" > "$DMC/max_freq" 2>/dev/null || true
        echo "dmc_ondemand" > "$DMC/governor" 2>/dev/null || true
        dialog --title "ERRO DE INTEGRIDADE" \
               --msgbox "Corrupcao detectada em ${cur_mhz} MHz!\nRevertido para 328 MHz." 8 48 < "$CURR_TTY" > "$CURR_TTY" 2>&1
    fi
}

while true; do
    [ -z "$(pgrep -f gptokeyb)" ] && Start_GPTKeyb
    CUR="$(cat "$DMC/cur_freq" 2>/dev/null || echo 0)"
    CUR_MHZ=$((CUR / 1000000))
    AVAIL="$(cat "$DMC/available_frequencies" 2>/dev/null | sed 's/000000/M/g')"

    CHOICE=$(dialog \
        --clear \
        --no-collapse \
        --cancel-label "Sair" \
        --backtitle "darkosen-k36 — Teste Seguro de RAM (DMC)" \
        --title "RAM Atual: ${CUR_MHZ} MHz" \
        --menu "Disponiveis: ${AVAIL}\nEscolha a frequencia para testar:" 16 55 6 \
        "1" "Voltar para 328 MHz (Padrao Seguro)" \
        "2" "Testar 450 MHz (+37% banda)" \
        "3" "Testar 528 MHz (+61% banda)" \
        "4" "Testar 666 MHz (+103% banda)" \
        "5" "Ver status detalhado (dmc + vdd_logic)" \
        "6" "Sair" \
        2>&1 < "$CURR_TTY" > "$CURR_TTY")

    [[ $? -ne 0 ]] && Exit_Menu

    case "$CHOICE" in
        1)
            echo "194000000" > "$DMC/min_freq" 2>/dev/null || true
            echo "328000000" > "$DMC/max_freq" 2>/dev/null || true
            echo "dmc_ondemand" > "$DMC/governor" 2>/dev/null || true
            dialog --msgbox "RAM revertida para 328 MHz (ondemand)!" 6 46 < "$CURR_TTY" > "$CURR_TTY" 2>&1
            ;;
        2) test_freq 450000000 "450 MHz" ;;
        3) test_freq 528000000 "528 MHz" ;;
        4) test_freq 666000000 "666 MHz" ;;
        5)
            VLOG="$(cat /sys/class/regulator/regulator.3/microvolts 2>/dev/null || echo '?')"
            GOV="$(cat "$DMC/governor" 2>/dev/null || echo '?')"
            dialog --title "Status DMC" \
                   --msgbox "Atual: ${CUR_MHZ} MHz\nGovernor: ${GOV}\nvdd_logic: ${VLOG} uV\nTabela: ${AVAIL}" 10 52 < "$CURR_TTY" > "$CURR_TTY" 2>&1
            ;;
        6|*) Exit_Menu ;;
    esac
done
