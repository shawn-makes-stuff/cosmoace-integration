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

# Keep-alive service (and the daemon it replaced, if still around).
for svc in ace-keepalive cosmoace-daemon; do
    if [ -f "/etc/init.d/${svc}" ]; then
        "/etc/init.d/${svc}" stop 2>/dev/null || true
        rm -f "/etc/init.d/${svc}" /etc/rc*.d/S*"${svc}"
    fi
done
rm -f /var/run/ace-keepalive.pid /var/run/cosmoace.sock /var/run/cosmoace-daemon.pid

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

# Optional toolhead sensor: remove the opt-in include and the staged file.
# Tolerate hand-written spacing, and never delete the file while any include
# still references it - Klipper refuses to start on a missing include.
TOOLHEAD_INCLUDE_RE='^[[:space:]]*\[include[[:space:]][[:space:]]*ace_toolhead\.cfg\][[:space:]]*$'
if [ -f "$PRINTER_CFG" ] && grep -q "$TOOLHEAD_INCLUDE_RE" "$PRINTER_CFG"; then
    echo "Removing ace_toolhead.cfg include from printer.cfg..."
    sed -i "/${TOOLHEAD_INCLUDE_RE}/d" "$PRINTER_CFG"
fi
if [ -f "$PRINTER_CFG" ] && grep -q 'ace_toolhead\.cfg' "$PRINTER_CFG"; then
    echo "WARNING: printer.cfg still references ace_toolhead.cfg in a form this script"
    echo "does not recognize; keeping ${KLIPPER_CONFIG_DIR}/ace_toolhead.cfg so Klipper can start."
    echo "Remove the include and the file by hand."
else
    rm -f "${KLIPPER_CONFIG_DIR}/ace_toolhead.cfg"
fi

echo "Removing ${ADDON_DIR}..."
rm -rf "$ADDON_DIR"

# Mainsail dashboard panel
rm -rf /user-resource/webui-addons/panels/cosmoace
# Bundled panel loader: remove only if we installed it and no other addon
# panels depend on it. Never touch a natively shipped extender.
if [ -f /user-resource/webui-addons/.cosmoace-bundled-loader ]; then
    if [ -n "$(ls -d /user-resource/webui-addons/panels/*/ 2>/dev/null)" ]; then
        echo "Other web UI panels present; keeping the bundled panel loader."
        [ -x /etc/init.d/cosmoace-webui ] && /etc/init.d/cosmoace-webui start
    else
        echo "Removing bundled Mainsail panel loader..."
        [ -x /etc/init.d/cosmoace-webui ] && /etc/init.d/cosmoace-webui remove
        rm -f /etc/init.d/cosmoace-webui /etc/rc*.d/S*cosmoace-webui
        rm -f /user-resource/webui-addons/loader.js \
              /user-resource/webui-addons/manifest.json \
              /user-resource/webui-addons/.cosmoace-bundled-loader
    fi
elif [ -x /etc/init.d/cosmoace-webui ]; then
    /etc/init.d/cosmoace-webui start   # refresh manifest without our panel
fi
rmdir /user-resource/webui-addons/panels /user-resource/webui-addons 2>/dev/null || true

echo "Restarting Klipper..."
/etc/init.d/klipper restart || echo "Warning: Klipper restart failed; restart it manually with: /etc/init.d/klipper restart"

echo "CosmoACE uninstalled. The stock COSMOS filament sensor behavior is restored."
