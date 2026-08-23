#!/bin/sh
# CosmoACE keep-alive poller.
#
# The ACE Pro drops its USB link ~3.5s after the last complete frame it
# received (comms watchdog) and re-enumerates. That kills feed assist
# mid-print and makes the next command fail with an I/O error. Anycubic's
# own firmware polls constantly; we only talk to the ACE when a macro runs,
# so something has to keep the link warm.
#
# This is deliberately a shell loop, not a Python service: busybox sh costs
# a few hundred KB, a Python interpreter costs ~5MB, and this board has
# 112MB total. It only writes one pre-built get_status frame per port and
# never reads a reply - it does not need to parse anything.
#
# Coordination with commands: ace-addon.py opens the port with an exclusive
# flock, and so does this poller, so the two can never interleave bytes in
# the middle of a frame. If a command holds the port, this tick is skipped
# (that command is feeding the watchdog itself anyway).

INTERVAL="${ACE_KEEPALIVE_INTERVAL:-2}"
BAUD=115200

# Pre-built frame: 0xFF 0xAA | len | {"id":0,"method":"get_status"} | CRC16
# MCRF4XX | 0xFE. Octal escapes so busybox printf emits it byte for byte
# (it contains a NUL). Regenerate if the payload ever changes.
FRAME='\377\252\036\000\173\042\151\144\042\072\060\054\042\155\145\164\150\157\144\042\072\042\147\145\164\137\163\164\141\164\165\163\042\175\311\072\376'

# ACE ports, found by USB product string rather than by device name. Two
# chained ACEs report the SAME by-id name, so by-id cannot tell them apart,
# and ttyACM numbering shifts between boots. Matching on the product also
# guarantees we never write to the printer's own MCU port.
SYSFS_USB="${ACE_SYSFS_USB:-/sys/bus/usb/devices}"

ace_ports() {
    for dev in "$SYSFS_USB"/*/; do
        [ -f "${dev}product" ] || continue
        read -r product < "${dev}product" 2>/dev/null || continue
        case "$product" in
            *ACE*) ;;
            *) continue ;;
        esac
        for tty in "$dev"*/tty/tty*; do
            [ -e "$tty" ] || continue
            echo "/dev/${tty##*/}"
        done
    done
}

while :; do
    for port in $(ace_ports); do
        [ -c "$port" ] || continue
        flock -n "$port" -c \
            "stty -F $port $BAUD raw -echo 2>/dev/null; printf '$FRAME' > $port" \
            2>/dev/null
    done
    sleep "$INTERVAL"
done
