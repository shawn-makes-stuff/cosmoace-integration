#!/bin/sh
# CosmoACE uninstaller for COSMOS firmware. Run as root: sh uninstall.sh
set -eu

ADDON_DIR="/user-resource/ace-addon"
KLIPPER_CONFIG_DIR="/etc/klipper/config"
PRINTER_CFG="${KLIPPER_CONFIG_DIR}/printer.cfg"
MACROS_CFG="${KLIPPER_CONFIG_DIR}/ace-addon.cfg"
BACKUP_DIR="${KLIPPER_CONFIG_DIR}/config-backups"
STAMP="$(date +%Y%m%d_%H%M%S)"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root." >&2
    exit 1
fi

# Remove the include line from printer.cfg (must go before deleting the cfg,
# otherwise Klipper fails to start on a missing include).
if [ -f "$PRINTER_CFG" ] && grep -q '^\[include ace-addon\.cfg\][[:space:]]*$' "$PRINTER_CFG"; then
    echo "Removing include from printer.cfg..."
    sed -i '/^\[include ace-addon\.cfg\][[:space:]]*$/d' "$PRINTER_CFG"
fi

# Legacy service and symlink from older CosmoACE versions.
if [ -f /etc/init.d/ace-addon ]; then
    /etc/init.d/ace-addon stop 2>/dev/null || true
    rm -f /etc/init.d/ace-addon /etc/rc*.d/S*ace-addon /etc/rc*.d/K*ace-addon
fi
rm -f "${KLIPPER_CONFIG_DIR}/klipper-readonly/ace-addon.cfg"

if [ -f "$MACROS_CFG" ]; then
    mkdir -p "$BACKUP_DIR"
    echo "Backing up macro config to ${BACKUP_DIR}/ace-addon-uninstall-${STAMP}.cfg"
    cp "$MACROS_CFG" "${BACKUP_DIR}/ace-addon-uninstall-${STAMP}.cfg" || true
    rm -f "$MACROS_CFG"
fi

echo "Removing ${ADDON_DIR}..."
rm -rf "$ADDON_DIR"

echo "Restarting Klipper..."
/etc/init.d/klipper restart || echo "Warning: Klipper restart failed; restart it manually with: /etc/init.d/klipper restart"

echo "CosmoACE uninstalled. The stock COSMOS filament sensor behavior is restored."
