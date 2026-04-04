#!/bin/sh
set -eu

ADDON_DIR="/user-resource/ace-addon"
INIT_SCRIPT="/etc/init.d/ace-addon"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root."
    exit 1
fi

if command -v service >/dev/null 2>&1; then
    service ace-addon stop || true
fi

rm -f /etc/rc0.d/K03ace-addon
rm -f /etc/rc1.d/K03ace-addon
rm -f /etc/rc2.d/S97ace-addon
rm -f /etc/rc5.d/S97ace-addon
rm -f /etc/rc6.d/K03ace-addon
rm -f "$INIT_SCRIPT"
rm -rf "$ADDON_DIR"

echo "ACE add-on uninstalled."
