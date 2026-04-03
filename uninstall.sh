#!/bin/sh
set -eu

ACE_ROOT="/etc/klipper/ace-addon"
ACE_RUNTIME="/etc/klipper/klippy-ace"
PRINTER_CFG="/etc/klipper/config/printer.cfg"
KLIPPER_INIT="/etc/init.d/klipper"
KLIPPER_INIT_BAK="/etc/init.d/klipper.ace-addon.bak"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root."
    exit 1
fi

if [ -f "$KLIPPER_INIT_BAK" ]; then
    cp -f "$KLIPPER_INIT_BAK" "$KLIPPER_INIT"
fi

if [ -f "$PRINTER_CFG" ]; then
    awk '
        BEGIN { skip=0 }
        /# BEGIN ACE ADDON/ { skip=1; next }
        /# END ACE ADDON/ { skip=0; next }
        skip==0 { print }
    ' "$PRINTER_CFG" > "${PRINTER_CFG}.tmp"
    mv "${PRINTER_CFG}.tmp" "$PRINTER_CFG"
fi

rm -rf "$ACE_RUNTIME"
rm -rf "$ACE_ROOT"

if command -v service >/dev/null 2>&1; then
    service klipper restart || true
    service moonraker restart || true
fi

echo "ACE add-on uninstalled."
