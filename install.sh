#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ADDON_DIR="/user-resource/ace-addon"
KLIPPER_CONFIG_DIR="/etc/klipper/config"
KLIPPER_READONLY_DIR="${KLIPPER_CONFIG_DIR}/klipper-readonly"
KLIPPER_USER_MACROS_CFG="${KLIPPER_CONFIG_DIR}/ace-addon.cfg"
KLIPPER_ADDON_CFG="${KLIPPER_READONLY_DIR}/ace-addon.cfg"
INIT_SCRIPT="/etc/init.d/ace-addon"
START_RUNLEVELS="2 3 4 5"
STOP_RUNLEVELS="0 1 6"
START_PRIORITY="97"
STOP_PRIORITY="10"

required_files="files/ace-addon.py files/ace-addon.conf files/ace-command.sh files/ace_macros.cfg files/ace-addon.init"

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

enable_service() {
    for rl in $START_RUNLEVELS; do
        if [ -d "/etc/rc${rl}.d" ]; then
            ln -sfn "../init.d/ace-addon" "/etc/rc${rl}.d/S${START_PRIORITY}ace-addon"
        fi
    done
    for rl in $STOP_RUNLEVELS; do
        if [ -d "/etc/rc${rl}.d" ]; then
            ln -sfn "../init.d/ace-addon" "/etc/rc${rl}.d/K${STOP_PRIORITY}ace-addon"
        fi
    done
}

mkdir -p "$ADDON_DIR"
mkdir -p "$KLIPPER_READONLY_DIR"
mkdir -p /etc/init.d

cp "${SCRIPT_DIR}/files/ace-addon.py" "${ADDON_DIR}/ace-addon.py"
cp "${SCRIPT_DIR}/files/ace-command.sh" "${ADDON_DIR}/ace-command.sh"
cp "${SCRIPT_DIR}/files/ace_macros.cfg" "${ADDON_DIR}/ace_macros.default.cfg"
cp "${SCRIPT_DIR}/files/ace-addon.init" "$INIT_SCRIPT"
chmod 0755 "${ADDON_DIR}/ace-addon.py" "${ADDON_DIR}/ace-command.sh" "$INIT_SCRIPT"
chmod 0644 "${ADDON_DIR}/ace_macros.default.cfg"

if [ ! -f "${KLIPPER_USER_MACROS_CFG}" ]; then
    if [ -f "${ADDON_DIR}/ace_macros.cfg" ]; then
        cp "${ADDON_DIR}/ace_macros.cfg" "${KLIPPER_USER_MACROS_CFG}"
    else
        cp "${SCRIPT_DIR}/files/ace_macros.cfg" "${KLIPPER_USER_MACROS_CFG}"
    fi
fi

rm -f "${ADDON_DIR}/ace_macros.cfg"
chmod 0644 "${KLIPPER_USER_MACROS_CFG}"
ln -sfn "${KLIPPER_USER_MACROS_CFG}" "${KLIPPER_ADDON_CFG}"
enable_service

if [ ! -f "${ADDON_DIR}/ace-addon.conf" ]; then
    cp "${SCRIPT_DIR}/files/ace-addon.conf" "${ADDON_DIR}/ace-addon.conf"
fi
chmod 0644 "${ADDON_DIR}/ace-addon.conf"

if command -v service >/dev/null 2>&1; then
    service ace-addon restart || service ace-addon start || true
    service klipper restart || true
fi

echo "ACE add-on installed."
echo "Configuration:"
echo "  $ADDON_DIR/ace-addon.conf"
echo "Service:"
echo "  $INIT_SCRIPT"
echo "Boot symlinks:"
echo "  enabled in /etc/rc2.d /etc/rc3.d /etc/rc4.d /etc/rc5.d"
echo "Klipper auto-include:"
echo "  $KLIPPER_ADDON_CFG -> $KLIPPER_USER_MACROS_CFG"
echo "Editable macros:"
echo "  $KLIPPER_USER_MACROS_CFG"
echo "Stock macro template:"
echo "  $ADDON_DIR/ace_macros.default.cfg"
echo "Sensor requirements:"
echo "  Update your existing filament_switch_sensor to set pause_on_runout: False"
echo "  Set runout_gcode: _ACE_SENSOR_EVENT EVENT=RUNOUT"
echo "  Set insert_gcode: _ACE_SENSOR_EVENT EVENT=INSERT"
