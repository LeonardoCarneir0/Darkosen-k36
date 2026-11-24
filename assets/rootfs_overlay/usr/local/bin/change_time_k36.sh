#!/bin/bash

#-----------------------#
# Date/Time Manager for ArkOS  #
#-----------------------#

# --- Root privilege check ---
if [ "$(id -u)" -ne 0 ]; then
    exec sudo -- "$0" "$@"
fi

set -euo pipefail

# --- Global Variables ---
CURR_TTY="/dev/tty1"
KEYBOARD="osk" # Use same input command as config_time.sh for date/time

# --- Initial Setup ---
printf "\033c" > "$CURR_TTY"
printf "\e[?25l" > "$CURR_TTY" # Hide cursor
dialog --clear
export TERM=linux
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
if [[ ! -e "/dev/input/by-path/platform-odroidgo2-joypad-event-joystick" ]]; then
    setfont /usr/share/consolefonts/Lat7-TerminusBold22x11.psf.gz
else
    setfont /usr/share/consolefonts/Lat7-Terminus16.psf.gz
fi

# --- Functions ---
check_timedatectl() {
    if ! command -v timedatectl &>/dev/null; then
        dialog --msgbox "Error: timedatectl not found. Please ensure systemd is installed." 6 50 > "$CURR_TTY"
        ExitMenu
    fi
}

check_osk() {
    if ! command -v "$KEYBOARD" &>/dev/null; then
        dialog --msgbox "Error: $KEYBOARD not found. Please ensure the on-screen keyboard is installed." 6 50 > "$CURR_TTY"
        ExitMenu
    fi
}

get_datetime_status() {
    local status="N/A"
    if command -v timedatectl &>/dev/null; then
        local timezone=$(timedatectl show --property=Timezone --value)
        local datetime=$(date '+%Y-%m-%d %H:%M:%S')
        status="Timezone: $timezone, Date/Time: $datetime"
    else
        status="timedatectl not found"
    fi
    echo "$status"
}

set_timezone() {
    local timezone_list=()
    while IFS= read -r tz; do
        timezone_list+=("$tz" "")
    done < <(timedatectl list-timezones)

    local selected_tz
    selected_tz=$(dialog --output-fd 1 \
        --backtitle "Date/Time Management v1.0 - ArkOS" \
        --title "Select Timezone" \
        --menu "Choose a timezone:" 15 50 7 \
        "${timezone_list[@]}" \
        2>"$CURR_TTY")

    if [[ -n "$selected_tz" ]]; then
        dialog --infobox "Setting timezone to $selected_tz..." 3 50 > "$CURR_TTY"
        timedatectl set-timezone "$selected_tz"
        sleep 1
        dialog --msgbox "Timezone set to $selected_tz." 5 50 > "$CURR_TTY"
    else
        dialog --msgbox "No timezone selected." 5 30 > "$CURR_TTY"
    fi
}

set_date() {
    check_osk
    local current_date=$(date '+%Y-%m-%d')
    local new_date
    pgrep -f gptokeyb | sudo xargs kill -9 2>/dev/null || true
    new_date=$("$KEYBOARD" "Enter date (YYYY-MM-DD)" 2>"$CURR_TTY")
    /opt/inttools/gptokeyb -1 "datetime-toggle.sh" -c "/opt/inttools/keys.gptk" >/dev/null 2>&1 &

    if [[ -n "$new_date" ]]; then
        if [[ "$new_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            dialog --infobox "Setting date to $new_date..." 3 50 > "$CURR_TTY"
            timedatectl set-time "$new_date" >/dev/null 2>&1
            if [[ $? -eq 0 ]]; then
                dialog --msgbox "Date set to $new_date." 5 50 > "$CURR_TTY"
            else
                dialog --msgbox "Error: Invalid date format or failed to set date." 6 50 > "$CURR_TTY"
            fi
        else
            dialog --msgbox "Error: Invalid date format (use YYYY-MM-DD)." 6 50 > "$CURR_TTY"
        fi
    else
        dialog --msgbox "No date entered." 5 30 > "$CURR_TTY"
    fi
}

set_time() {
    check_osk
    local current_time=$(date '+%H:%M')
    local new_time
    pgrep -f gptokeyb | sudo xargs kill -9 2>/dev/null || true
    new_time=$("$KEYBOARD" "Enter time (HH:MM, 24-hour)" 2>"$CURR_TTY")
    /opt/inttools/gptokeyb -1 "datetime-toggle.sh" -c "/opt/inttools/keys.gptk" >/dev/null 2>&1 &

    if [[ -n "$new_time" ]]; then
        if [[ "$new_time" =~ ^[0-2][0-9]:[0-5][0-9]$ ]]; then
            new_time="${new_time}:00" # Append :00 for seconds
            dialog --infobox "Setting time to $new_time..." 3 50 > "$CURR_TTY"
            timedatectl set-time "$new_time" >/dev/null 2>&1
            if [[ $? -eq 0 ]]; then
                dialog --msgbox "Time set to $new_time." 5 50 > "$CURR_TTY"
            else
                dialog --msgbox "Error: Invalid time format or failed to set time." 6 50 > "$CURR_TTY"
            fi
        else
            dialog --msgbox "Error: Invalid time format (use HH:MM)." 6 50 > "$CURR_TTY"
        fi
    else
        dialog --msgbox "No time entered." 5 30 > "$CURR_TTY"
    fi
}

ExitMenu() {
    printf "\033c" > "$CURR_TTY"
    printf "\e[?25h" > "$CURR_TTY" # Show cursor
    pkill -f "gptokeyb -1 datetime-toggle.sh" || true
    if [[ ! -e "/dev/input/by-path/platform-odroidgo2-joypad-event-joystick" ]]; then
        setfont /usr/share/consolefonts/Lat7-Terminus20x10.psf.gz # Restore a common font
    fi
    exit 0
}

MainMenu() {
    check_timedatectl
    while true; do
        local DATETIME_STATUS
        DATETIME_STATUS=$(get_datetime_status)
        local CHOICE
        CHOICE=$(dialog --output-fd 1 \
            --backtitle "Date/Time Management v1.0 - ArkOS" \
            --title "Date/Time Manager" \
            --menu "\nCurrent Status: $DATETIME_STATUS" 16 60 4 \
            1 "Set Timezone" \
            2 "Set Date" \
            3 "Set Time" \
            6 "Exit" \
            2>"$CURR_TTY")

        case $CHOICE in
            1) set_timezone ;;
            2) set_date ;;
            3) set_time ;;
            6) ExitMenu ;;
            *) ExitMenu ;;
        esac
    done
}

# --- Main Execution ---
trap ExitMenu EXIT SIGINT SIGTERM # Clean up on exit

# gptokeyb setup for joystick control in dialog
if command -v /opt/inttools/gptokeyb &>/dev/null; then
    if [[ -e /dev/uinput ]]; then
        chmod 666 /dev/uinput 2>/dev/null || true # Ensure gptokeyb can access uinput
    fi
    export SDL_GAMECONTROLLERCONFIG_FILE="/opt/inttools/gamecontrollerdb.txt"
    pkill -f "gptokeyb -1 datetime-toggle.sh" || true # Kill previous instances
    /opt/inttools/gptokeyb -1 "datetime-toggle.sh" -c "/opt/inttools/keys.gptk" >/dev/null 2>&1 &
else
    dialog --infobox "gptokeyb not found. Joystick control disabled." 5 65 > "$CURR_TTY"
    sleep 2
fi

printf "\033c" > "$CURR_TTY" # Clear screen before showing menu
MainMenu