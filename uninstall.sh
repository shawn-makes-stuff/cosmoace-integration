#!/bin/sh
set -eu

ADDON_DIR="/user-resource/ace-addon"
KLIPPER_USER_MACROS_CFG="/etc/klipper/config/ace-addon.cfg"
KLIPPER_ADDON_CFG="/etc/klipper/config/klipper-readonly/ace-addon.cfg"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root."
    exit 1
fi

echo "Remounting root as RW..."
mount -o remount,rw / || echo "Warning: Could not remount root as RW."

if [ -f "/etc/init.d/ace-addon" ]; then
    echo "Stopping service..."
    if command -v service >/dev/null 2>&1; then
        service ace-addon stop || true
    fi
    rm -f /etc/init.d/ace-addon
    rm -f /etc/rc*.d/S*ace-addon
    rm -f /etc/rc*.d/K*ace-addon
fi

echo "Removing files..."
rm -f "$KLIPPER_ADDON_CFG"
rm -rf "$ADDON_DIR"

if command -v service >/dev/null 2>&1; then
    echo "Restarting Klipper..."
    service klipper restart || true
elif command -v systemctl >/dev/null 2>&1; then
    echo "Restarting Klipper..."
    systemctl restart klipper || true
fi

echo "Remounting root as RO..."
mount -o remount,ro / || echo "Warning: Could not remount root as RO."

echo "ACE add-on uninstalled."
echo "Preserved editable macro file (manual deletion required if desired):"
echo "  $KLIPPER_USER_MACROS_CFG"
