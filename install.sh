#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ADDON_DIR="/user-resource/ace-addon"
KLIPPER_CONFIG_DIR="/etc/klipper/config"
KLIPPER_READONLY_DIR="${KLIPPER_CONFIG_DIR}/klipper-readonly"
KLIPPER_USER_MACROS_CFG="${KLIPPER_CONFIG_DIR}/ace-addon.cfg"
KLIPPER_ADDON_CFG="${KLIPPER_READONLY_DIR}/ace-addon.cfg"

required_files="files/ace-addon.py files/ace-addon.conf files/ace-command.sh files/ace_macros.cfg"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root."
    exit 1
fi

for file in $required_files; do
    if [ ! -f "${SCRIPT_DIR}/${file}" ]; then
        echo "Missing ${file} in add-on directory."
        exit 1
    fi
done

echo "Remounting root as RW..."
mount -o remount,rw / || echo "Warning: Could not remount root as RW. Proceeding anyway..."

# Stop and remove the old service if it exists
if [ -f "/etc/init.d/ace-addon" ]; then
    echo "Removing old service..."
    if command -v service >/dev/null 2>&1; then
        service ace-addon stop || true
    fi
    rm -f /etc/init.d/ace-addon
    rm -f /etc/rc*.d/S*ace-addon
    rm -f /etc/rc*.d/K*ace-addon
fi

mkdir -p "$ADDON_DIR"
mkdir -p "$KLIPPER_READONLY_DIR"

echo "Copying files..."
cp "${SCRIPT_DIR}/files/ace-addon.py" "${ADDON_DIR}/ace-addon.py"
cp "${SCRIPT_DIR}/files/ace-command.sh" "${ADDON_DIR}/ace-command.sh"
cp "${SCRIPT_DIR}/files/ace_macros.cfg" "${ADDON_DIR}/ace_macros.default.cfg"
chmod 0755 "${ADDON_DIR}/ace-addon.py" "${ADDON_DIR}/ace-command.sh"
chmod 0644 "${ADDON_DIR}/ace_macros.default.cfg"

if [ ! -f "${KLIPPER_USER_MACROS_CFG}" ]; then
    echo "Installing default macro config..."
    cp "${SCRIPT_DIR}/files/ace_macros.cfg" "${KLIPPER_USER_MACROS_CFG}"
else
    echo "Preserving existing macro config at ${KLIPPER_USER_MACROS_CFG}"
fi

chmod 0644 "${KLIPPER_USER_MACROS_CFG}"
ln -sfn "${KLIPPER_USER_MACROS_CFG}" "${KLIPPER_ADDON_CFG}"

if [ ! -f "${ADDON_DIR}/ace-addon.conf" ]; then
    cp "${SCRIPT_DIR}/files/ace-addon.conf" "${ADDON_DIR}/ace-addon.conf"
fi
chmod 0644 "${ADDON_DIR}/ace-addon.conf"

# Restart Klipper
if command -v service >/dev/null 2>&1; then
    echo "Restarting Klipper..."
    service klipper restart || true
elif command -v systemctl >/dev/null 2>&1; then
    echo "Restarting Klipper..."
    systemctl restart klipper || true
fi

echo "Remounting root as RO..."
mount -o remount,ro / || echo "Warning: Could not remount root as RO."

echo "ACE add-on (CLI) installed."
echo "Configuration:      $ADDON_DIR/ace-addon.conf"
echo "Editable macros:    $KLIPPER_USER_MACROS_CFG"
