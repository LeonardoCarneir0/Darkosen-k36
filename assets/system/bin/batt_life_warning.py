#!/usr/bin/env python3

import os
import sys
import time
import subprocess

batt_life = "/sys/class/power_supply/battery/capacity"

# Function to get the state of GPIO 77
def get_gpio_state():
    try:
        output = subprocess.check_output("cat /sys/kernel/debug/gpio | grep 'gpio-77'", shell=True).decode()
        return "hi" in output  # Check if the signal level is high
    except subprocess.CalledProcessError:
        return None

# Main loop to check battery level
while True:
    try:
        battery_level = int(open(batt_life, "r").read())

        if battery_level <= 10:
            if not get_gpio_state():
                print("Turning on LED (blinking every second)")
                time.sleep(1)
            else:
                print("Turning off LED (blinking every second)")
                time.sleep(1)

        elif battery_level <= 20:
            if not get_gpio_state():
                print("Turning on LED (blinking every 30 seconds)")
                time.sleep(30)

        else:
            if get_gpio_state():
                print("Turning off LED (blinking every 30 seconds)")
                time.sleep(30)
            else:
                time.sleep(30)

    except Exception as e:
        print(f"Error: {e}")
        time.sleep(5)