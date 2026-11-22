#!/bin/bash
ZRAM_SIZE_MB=512
ZRAM_ALGORITHM=lz4
[ -f /etc/zram.conf ] && source /etc/zram.conf
modprobe zram num_devices=1 2>/dev/null
for i in {1..10}; do [ -b /dev/zram0 ] && break; sleep 0.5; done
[ ! -b /dev/zram0 ] && exit 1
if [ -f /sys/block/zram0/comp_algorithm ] && grep -q "$ZRAM_ALGORITHM" /sys/block/zram0/comp_algorithm; then
    echo "$ZRAM_ALGORITHM" > /sys/block/zram0/comp_algorithm 2>/dev/null
fi
echo $((ZRAM_SIZE_MB * 1024 * 1024)) > /sys/block/zram0/disksize
mkswap /dev/zram0 >/dev/null 2>&1
swapon -p 5 /dev/zram0
exit 0
