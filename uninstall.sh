#!/bin/sh
set -eu

ADDON_DIR="/user-resource/ace-addon"
KLIPPER_USER_MACROS_CFG="/etc/klipper/config/ace-addon.cfg"
KLIPPER_ADDON_CFG="/etc/klipper/config/klipper-readonly/ace-addon.cfg"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root."
    exit 1
fi

if [ -f "/etc/init.d/ace-addon" ]; then
    if command -v service >/dev/null 2>&1; then
        service ace-addon stop || true
    fi
    rm -f /etc/init.d/ace-addon
    rm -f /etc/rc*.d/S*ace-addon
    rm -f /etc/rc*.d/K*ace-addon
fi

rm -f "$KLIPPER_ADDON_CFG"
rm -rf "$ADDON_DIR"

if command -v service >/dev/null 2>&1; then
    service klipper restart || true
fi

echo "ACE add-on uninstalled."
echo "Preserved editable macro file:"
echo "  $KLIPPER_USER_MACROS_CFG"
