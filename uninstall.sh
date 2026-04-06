#!/bin/sh
set -eu

ADDON_DIR="/user-resource/ace-addon"
KLIPPER_USER_MACROS_CFG="/etc/klipper/config/ace-addon.cfg"
KLIPPER_ADDON_CFG="/etc/klipper/config/klipper-readonly/ace-addon.cfg"
INIT_SCRIPT="/etc/init.d/ace-addon"
START_RUNLEVELS="2 3 4 5"
STOP_RUNLEVELS="0 1 6"
START_PRIORITY="97"
STOP_PRIORITY="10"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root."
    exit 1
fi

if command -v service >/dev/null 2>&1; then
    service ace-addon stop || true
fi

for rl in $START_RUNLEVELS; do
    rm -f "/etc/rc${rl}.d/S${START_PRIORITY}ace-addon"
done

for rl in $STOP_RUNLEVELS; do
    rm -f "/etc/rc${rl}.d/K${STOP_PRIORITY}ace-addon"
done

rm -f "$KLIPPER_ADDON_CFG"
rm -f "$INIT_SCRIPT"
rm -rf "$ADDON_DIR"

if command -v service >/dev/null 2>&1; then
    service klipper restart || true
fi

echo "ACE add-on uninstalled."
echo "Preserved editable macro file:"
echo "  $KLIPPER_USER_MACROS_CFG"
