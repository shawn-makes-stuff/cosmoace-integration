#!/bin/sh
set -eu

ACE_ROOT="/etc/klipper/ace-addon"
ACE_RUNTIME="/etc/klipper/klippy-ace"
ACE_KLIPPY_DIR="${ACE_RUNTIME}/klippy"
ACE_CONFIG="/etc/klipper/config/ace-user.cfg"
PRINTER_CFG="/etc/klipper/config/printer.cfg"
KLIPPER_INIT="/etc/init.d/klipper"
KLIPPER_INIT_BAK="/etc/init.d/klipper.ace-addon.bak"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root."
    exit 1
fi

if [ ! -f "${SCRIPT_DIR}/files/ace.py" ] || [ ! -f "${SCRIPT_DIR}/files/ace-user.cfg" ]; then
    echo "Missing files/ace.py or files/ace-user.cfg in add-on directory."
    exit 1
fi

if [ ! -f "$KLIPPER_INIT" ]; then
    echo "Missing $KLIPPER_INIT"
    exit 1
fi

if [ ! -f "/usr/share/klipper/klippy/klippy.py" ]; then
    echo "Missing /usr/share/klipper/klippy/klippy.py"
    exit 1
fi

mkdir -p "$ACE_ROOT"
cp -f "${SCRIPT_DIR}/files/ace.py" "$ACE_ROOT/ace.py"

# Build writable runtime copy of Klippy tree, then inject ACE extra.
rm -rf "$ACE_RUNTIME"
mkdir -p "$ACE_RUNTIME"
cp -a /usr/share/klipper/klippy "$ACE_RUNTIME/"
cp -f "$ACE_ROOT/ace.py" "$ACE_KLIPPY_DIR/extras/ace.py"
# Provide expected klippy source metadata paths for Moonraker.
if [ -d /usr/share/klipper/config ]; then
    ln -sfn /usr/share/klipper/config "$ACE_RUNTIME/config"
else
    mkdir -p "$ACE_RUNTIME/config"
fi
if [ -d /usr/share/klipper/docs ]; then
    ln -sfn /usr/share/klipper/docs "$ACE_RUNTIME/docs"
else
    mkdir -p "$ACE_RUNTIME/docs"
fi

# Keep a one-time backup of the original init script.
if [ ! -f "$KLIPPER_INIT_BAK" ]; then
    cp -f "$KLIPPER_INIT" "$KLIPPER_INIT_BAK"
fi

# Point Klipper service to writable runtime tree.
sed -i 's|/usr/share/klipper/klippy/klippy.py|/etc/klipper/klippy-ace/klippy/klippy.py|g' "$KLIPPER_INIT"
sed -i 's|/etc/klipper/klippy-ace/klippy.py|/etc/klipper/klippy-ace/klippy/klippy.py|g' "$KLIPPER_INIT"

# Install user-tunable ACE config if it does not exist yet.
if [ ! -f "$ACE_CONFIG" ]; then
    cp -f "${SCRIPT_DIR}/files/ace-user.cfg" "$ACE_CONFIG"
fi

# Merge ACE panel macros into existing config once.
if ! grep -q "gcode_macro ACE_PANEL_FEED_SLOT" "$ACE_CONFIG"; then
    awk '
        /^# ACE panel controls for Mainsail\/Moonraker macro UI/ { copy=1 }
        copy==1 { print }
    ' "${SCRIPT_DIR}/files/ace-user.cfg" >> "$ACE_CONFIG"
fi

# Add include marker block to printer.cfg once.
if ! grep -q "BEGIN ACE ADDON" "$PRINTER_CFG"; then
    {
        echo ""
        echo "# BEGIN ACE ADDON"
        echo "[include ace-user.cfg]"
        echo "# END ACE ADDON"
    } >> "$PRINTER_CFG"
fi

if command -v service >/dev/null 2>&1; then
    service klipper restart || true
    service moonraker restart || true
fi

echo "ACE add-on installed."
echo "Edit $ACE_CONFIG and set [ace] enabled: True when ready."
echo "Then restart klipper: service klipper restart"
