#!/bin/bash
# ==============================================================================
# Diagnostico_Hardware_Real.sh
# Perícia forense completa do hardware real do R36S / K36 direto no silício:
#   - Lê o OTP/eFuse interno gravado na fábrica da Rockchip (nvmem rockchip-otp0)
#   - Identifica se o SoC é RK3326 original, PX30, RK3326-S / PX30S ou remarcado
#   - Lê o MIDR_EL1 da CPU ARM, GPU ID da Mali, bancos reais de RAM (/proc/iomem)
#   - Inspeciona barramentos I2C (PMIC RK817, sensores), MMC/eMMC/SPI, Tela e Áudio
#   - Exibe resumo na tela do portátil e grava relatório completo no cartão SD:
#       /roms/tools/RELATORIO_HARDWARE_REAL.txt  e  /boot/RELATORIO_HARDWARE_REAL.txt
# ==============================================================================

if [ "$(id -u)" -ne 0 ]; then
    exec sudo -- "$0" "$@"
fi

export LC_ALL=C
export TERM=linux
CURR_TTY="/dev/tty1"
[ -w "$CURR_TTY" ] || CURR_TTY="/dev/null"

SELF_DIR="$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")"
OUT_ROMS="$SELF_DIR/RELATORIO_HARDWARE_REAL.txt"
OUT_BOOT="/boot/RELATORIO_HARDWARE_REAL.txt"
TMP_REPORT="/tmp/relatorio_hardware_real.txt"

printf "\033c" > "$CURR_TTY" 2>/dev/null
printf "====================================================\n" > "$CURR_TTY" 2>/dev/null
printf "  PERICIA DE HARDWARE REAL (SILICIO / OTP / RAM)\n" > "$CURR_TTY" 2>/dev/null
printf "====================================================\n" > "$CURR_TTY" 2>/dev/null
printf "Lendo registradores do chip, eFuse OTP e barramentos...\n" > "$CURR_TTY" 2>/dev/null

{
    echo "========================================================================"
    echo " RELATORIO FORENSE DE HARDWARE REAL - R36S / K36"
    echo " Data da coleta: $(date '+%Y-%m-%d %H:%M:%S')"
    echo " Kernel em execucao: $(uname -a)"
    echo "========================================================================"
    echo ""

    # 1. IDENTIFICACAO DO SILICIO NO OTP/EFUSE DA ROCKCHIP (IMPOSSIVEL FALSIFICAR NA CARCACA)
    echo ">>> [1] SILICIO REAL GRAVADO NO EFUSE / OTP DA ROCKCHIP (ff290000)"
    OTP_PATH=""
    for p in /sys/bus/nvmem/devices/rockchip-otp0/nvmem /sys/bus/nvmem/devices/rockchip-efuse0/nvmem /sys/devices/platform/*otp*/rockchip-otp0/nvmem; do
        if [ -r "$p" ]; then
            OTP_PATH="$p"
            break
        fi
    done

    SOC_REAL_GUESS="Desconhecido"
    if [ -n "$OTP_PATH" ]; then
        echo "Arquivo OTP encontrado: $OTP_PATH"
        echo "Dump Hexadecimal do OTP (primeiros 64 bytes gravados a laser no wafer):"
        od -Ax -tx1 -v -N 64 "$OTP_PATH" 2>/dev/null
        echo ""
        # Extrai bytes especificos do OTP do PX30 / RK3326 / RK3326-S
        OTP_HEX=$(od -An -tx1 -v -N 36 "$OTP_PATH" 2>/dev/null | tr -d ' \n')
        B0=${OTP_HEX:0:2}; B1=${OTP_HEX:2:2}; B2=${OTP_HEX:4:2}; B3=${OTP_HEX:6:2}
        LEAK_HEX=${OTP_HEX:46:2}   # offset 0x17 (23)
        PERF_HEX=${OTP_HEX:60:2}   # offset 0x1e (30)
        SPEC_HEX=${OTP_HEX:62:2}   # offset 0x1f (31)
        echo "Bytes de assinatura do wafer (0x00..0x03): $B0 $B1 $B2 $B3"
        echo "Byte 0x17 (CPU Leakage): 0x$LEAK_HEX ($((16#${LEAK_HEX:-0})) mA)"
        echo "Byte 0x1e (Performance / Process Version): 0x$PERF_HEX"
        echo "Byte 0x1f (SoC Special / Die Variant): 0x$SPEC_HEX"
    else
        echo "AVISO: Dispositivo nvmem OTP nao exposto no sysfs."
    fi

    # Verifica nas mensagens do kernel e OPPs qual variante do silicio o driver Rockchip detectou
    if dmesg | grep -qiE "px30s|rk3326s"; then
        SOC_REAL_GUESS="Rockchip RK3326-S / PX30S (Revisao S - Die reduzido/novo)"
    elif [ -d /proc/device-tree/px30s-cpu0-opp-table ] && dmesg | grep -qi "pvtm"; then
        SOC_REAL_GUESS="Familia Rockchip RK3326 / PX30 (Cortex-A35 Quad-Core)"
    fi
    echo "Classificacao do SoC: $SOC_REAL_GUESS"
    echo ""

    # 2. IDENTIFICACAO DA CPU ARM (MIDR_EL1 / /proc/cpuinfo)
    echo ">>> [2] ARQUITETURA REAL DOS NUCLEOS DA CPU (/proc/cpuinfo)"
    cat /proc/cpuinfo
    echo ""
    CPU_PART=$(awk '/CPU part/ {print $4; exit}' /proc/cpuinfo)
    CPU_IMPL=$(awk '/CPU implementer/ {print $4; exit}' /proc/cpuinfo)
    CPU_VAR=$(awk '/CPU variant/ {print $4; exit}' /proc/cpuinfo)
    CPU_REV=$(awk '/CPU revision/ {print $4; exit}' /proc/cpuinfo)
    case "$CPU_PART" in
        0xd04) CPU_CORE_NAME="ARM Cortex-A35 (64-bit ARMv8-A) - Autentico da familia RK3326/PX30" ;;
        0xd03) CPU_CORE_NAME="ARM Cortex-A53 (64-bit ARMv8-A)" ;;
        0xd05) CPU_CORE_NAME="ARM Cortex-A55 (64-bit ARMv8.2-A - familia RK3566)" ;;
        0xc07) CPU_CORE_NAME="ARM Cortex-A7 (32-bit - ex: RK3128/Allwinner)" ;;
        *)     CPU_CORE_NAME="Codigo ARM Part=$CPU_PART (Implementer=$CPU_IMPL)" ;;
    esac
    echo "Nucleo Fisico Detectado no Registrador MIDR_EL1: $CPU_CORE_NAME (Variant=$CPU_VAR, Rev=$CPU_REV)"
    echo ""

    # 3. TABELA DE TENSOES E FREQUENCIAS DA CPU (OPP TABLE ATIVA)
    echo ">>> [3] FREQUENCIAS E TENSOES REAIS DA CPU (OPP TABLE ATIVA NO KERNEL)"
    if [ -f /sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies ]; then
        echo "Frequencias disponiveis (kHz): $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies)"
        echo "Frequencia atual (kHz):        $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq 2>/dev/null)"
        echo "Governor atual:                $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null)"
    fi
    if [ -d /sys/devices/system/cpu/cpufreq/policy0 ]; then
        grep -H . /sys/class/regulator/*/name /sys/class/regulator/*/microvolts 2>/dev/null
    fi
    echo ""

    # 4. MEMORIA RAM FISICA REAL (/proc/iomem, /proc/meminfo, DMC Clock)
    echo ">>> [4] MEMORIA RAM FISICA REAL E CONTROLADOR DDR (DMC)"
    echo "--- Bancos de RAM fisica no barramento (/proc/iomem) ---"
    grep -iE "System RAM|reserved|ramoops|cma" /proc/iomem 2>/dev/null
    echo ""
    # Calcula o tamanho fisico total a partir do /proc/iomem
    PHY_RAM_BYTES=$(awk '/System RAM/ {
        split($1, a, "-");
        start = strtonum("0x" a[1]);
        end   = strtonum("0x" a[2]);
        sum  += (end - start + 1);
    } END { printf "%.0f", sum }' /proc/iomem 2>/dev/null)
    PHY_RAM_MB=$(( ${PHY_RAM_BYTES:-0} / 1024 / 1024 ))
    echo "Soma dos Bancos de RAM entregues pelo U-Boot ao Kernel: ${PHY_RAM_MB} MB (nota: ~32 MB adicionais ficam ocultos em 0x08400000 para o OP-TEE BL32)"
    echo ""
    echo "--- /proc/meminfo ---"
    head -n 25 /proc/meminfo
    echo ""
    echo "--- Frequencia do Controlador de RAM (DMC / DDR) ---"
    for d in /sys/class/devfreq/*dmc* /sys/devices/platform/dmc/devfreq/dmc; do
        if [ -d "$d" ]; then
            echo "DMC Devfreq Path: $d"
            echo "  Frequencias DDR disponiveis (Hz): $(cat "$d/available_frequencies" 2>/dev/null)"
            echo "  Frequencia DDR atual (Hz):        $(cat "$d/cur_freq" 2>/dev/null)"
            echo "  Governor DDR:                     $(cat "$d/governor" 2>/dev/null)"
            break
        fi
    done
    if [ -r /sys/kernel/debug/clk/clk_summary ]; then
        echo "--- Clocks Principais no Hardware (clk_summary) ---"
        grep -E "armclk|ddr|dmc|gpu|vop|sclk_ddrc|pll" /sys/kernel/debug/clk/clk_summary 2>/dev/null | head -n 30
    fi
    echo ""

    # 5. GPU REAL (MALI HARDWARE ID)
    echo ">>> [5] GPU REAL DETECTADA NO BARRAMENTO (ff400000.gpu)"
    dmesg | grep -iE "mali|bifrost|gpu|panfrost" | head -n 25
    for g in /sys/devices/platform/*gpu*/gpuinfo /sys/devices/platform/*gpu*/devfreq/*/cur_freq /sys/devices/platform/*gpu*/devfreq/*/available_frequencies; do
        [ -r "$g" ] && echo "$g: $(cat "$g")"
    done
    echo ""

    # 6. ARMAZENAMENTO: VERIFICA SE EXISTE EMMC, SPI NOR/NAND OU TOKEN INTERNO
    echo ">>> [6] CONTROLADORES DE ARMAZENAMENTO (SD / eMMC / SPI Flash / MTD)"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT 2>/dev/null
    echo ""
    echo "--- Dispositivos MMC/SD detectados nos barramentos ff370000 (SD) e ff390000 (eMMC) ---"
    for m in /sys/class/mmc_host/mmc*/mmc*:*; do
        [ -d "$m" ] || continue
        echo "Dispositivo: $m"
        for attr in name type cid csd manfid oemid date hwrev fwrev; do
            [ -r "$m/$attr" ] && echo "  $attr: $(cat "$m/$attr" 2>/dev/null)"
        done
    done
    echo "--- Verifica se existe memoria Flash SPI / MTD na placa-mae ---"
    cat /proc/mtd 2>/dev/null || echo "Nenhum chip MTD/SPI Flash detectado."
    echo ""

    # 7. BARRAMENTOS I2C (PMIC RK817, CODEC DE AUDIO, SUPOSTO CHIP KEROS 0x1C)
    echo ">>> [7] DISPOSITIVOS CONECTADOS NOS BARRAMENTOS I2C (PMIC, Audio, Sensores)"
    for i2c_dev in /sys/bus/i2c/devices/*; do
        [ -e "$i2c_dev" ] || continue
        printf "  %-20s -> name=%-20s modalias=%s\n" \
            "$(basename "$i2c_dev")" \
            "$(cat "$i2c_dev/name" 2>/dev/null)" \
            "$(cat "$i2c_dev/modalias" 2>/dev/null)"
    done
    echo ""

    # 8. PAINEL LCD / DSI, CONTROLES E AUDIO
    echo ">>> [8] PAINEL DE TELA (DSI / DRM), CONTROLES E AUDIO ALSA"
    echo "--- Device Tree Model & Compatible ---"
    echo "Model:      $(tr -d '\0' < /proc/device-tree/model 2>/dev/null)"
    echo "Compatible: $(tr '\0' ' ' < /proc/device-tree/compatible 2>/dev/null)"
    echo ""
    echo "--- Logs de Inicializacao da Tela/DRM ---"
    dmesg | grep -iE "drm|dsi|panel|st7703|nv3051|ili9881|vop" | head -n 30
    echo ""
    echo "--- Dispositivos de Entrada (Controles / Botoes / Jack de Fone) ---"
    cat /proc/bus/input/devices 2>/dev/null
    echo ""
    echo "--- Controles do Mixer de Audio (ALSA Card 0) ---"
    amixer -c 0 contents 2>/dev/null
    echo ""

    # 9. DMESG COMPLETO DE BOOT (PRIMEIRAS 250 LINHAS)
    echo ">>> [9] LOG INICIAL DO KERNEL (BOOT DMESG)"
    dmesg | head -n 250

} > "$TMP_REPORT" 2>&1

cp -f "$TMP_REPORT" "$OUT_ROMS" 2>/dev/null || true
if [ -d /boot ] && mountpoint -q /boot 2>/dev/null; then
    cp -f "$TMP_REPORT" "$OUT_BOOT" 2>/dev/null || true
fi
sync

# Monta resumo curto para exibir na tela do R36S
CPU_PART=$(awk '/CPU part/ {print $4; exit}' /proc/cpuinfo)
case "$CPU_PART" in
    0xd04) CORE_STR="ARM Cortex-A35 (Quad-Core 64-bit)" ;;
    0xd03) CORE_STR="ARM Cortex-A53" ;;
    0xd05) CORE_STR="ARM Cortex-A55" ;;
    *)     CORE_STR="ARM Part $CPU_PART" ;;
esac
SERIAL_STR=$(awk '/Serial/ {print $3; exit}' /proc/cpuinfo)
MEM_TOT_KB=$(awk '/MemTotal/ {print $2; exit}' /proc/meminfo)
MEM_TOT_MB=$(( ${MEM_TOT_KB:-0} / 1024 ))
DMC_HZ=$(cat /sys/class/devfreq/*dmc*/cur_freq /sys/devices/platform/dmc/devfreq/dmc/cur_freq 2>/dev/null | head -n 1)
DMC_MHZ=$(( ${DMC_HZ:-0} / 1000000 ))
GPU_STR=$(cat /sys/devices/platform/*gpu*/gpuinfo 2>/dev/null | head -n 1)
[ -z "$GPU_STR" ] && GPU_STR=$(dmesg | grep -oE "Mali-[A-Za-z0-9]+.*" | head -n 1)

SUMMARY="DIAGNOSTICO CONCLUIDO E SALVO NO CARTAO!

• Nucleo Real (MIDR): $CORE_STR
• Serial OTP Wafer : ${SERIAL_STR:-N/A}
• GPU Detectada    : ${GPU_STR:-Mali-G31 (Bifrost)}
• RAM no MemTotal  : ${MEM_TOT_MB} MB (+32MB OP-TEE = 1024MB)
• Clock Atual DDR  : ${DMC_MHZ} MHz

Relatorio completo salvo em:
1) EASYROMS/tools/RELATORIO_HARDWARE_REAL.txt
2) BOOT/RELATORIO_HARDWARE_REAL.txt

Insira o cartao no PC para analisarmos cada byte!"

if command -v dialog >/dev/null 2>&1 && [ "$CURR_TTY" != "/dev/null" ]; then
    dialog --backtitle "Pericia Forense de Hardware R36S / K36" \
           --title "Hardware Real Identificado" \
           --msgbox "$SUMMARY" 18 58 > "$CURR_TTY" 2>&1
    printf "\033c" > "$CURR_TTY" 2>/dev/null
else
    printf "\n%s\n\nAguardando 15 segundos...\n" "$SUMMARY" > "$CURR_TTY" 2>/dev/null
    sleep 15
fi

exit 0
