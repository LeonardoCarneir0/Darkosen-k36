#!/usr/bin/env python3

import evdev
import asyncio
import time
import os
from subprocess import check_output

arkos_joypad = evdev.InputDevice("/dev/input/event0")

class Joypad:
    l1 = 310
    r1 = 311

    up = 544
    down = 545
    left = 546
    right = 547

    f2 = 314
    f3 = 315
    fn = 464

def runcmd(cmd, *args, **kw):
    print(f">>> {cmd}")
    check_output(cmd, *args, **kw)

async def handle_event(device):
    async for event in device.async_read_loop():
        if device.name == "play_joystick":
            keys = arkos_joypad.active_keys()
            if Joypad.f2 in keys:
                if event.code == Joypad.f3:
                    runcmd("pkill OpenBOR", shell=True)
                    exit

def run():
    asyncio.ensure_future(handle_event(arkos_joypad))

    loop = asyncio.get_event_loop()
    loop.run_forever()

if __name__ == "__main__": # admire
    run()

