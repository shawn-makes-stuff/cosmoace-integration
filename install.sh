#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ADDON_DIR="/user-resource/ace-addon"
INIT_SCRIPT="/etc/init.d/ace-addon"

required_files="files/ace-addon.py files/ace-addon.conf files/ace-panel.html files/ace-addon.init"

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

mkdir -p "$ADDON_DIR"

install -m 0755 "${SCRIPT_DIR}/files/ace-addon.py" "${ADDON_DIR}/ace-addon.py"
install -m 0755 "${SCRIPT_DIR}/files/ace-addon.init" "$INIT_SCRIPT"
install -m 0644 "${SCRIPT_DIR}/files/ace-panel.html" "${ADDON_DIR}/ace-panel.html"

if [ ! -f "${ADDON_DIR}/ace-addon.conf" ]; then
    install -m 0644 "${SCRIPT_DIR}/files/ace-addon.conf" "${ADDON_DIR}/ace-addon.conf"
fi

for rcdir in /etc/rc0.d /etc/rc1.d /etc/rc2.d /etc/rc5.d /etc/rc6.d; do
    mkdir -p "$rcdir"
done

ln -sfn ../init.d/ace-addon /etc/rc2.d/S97ace-addon
ln -sfn ../init.d/ace-addon /etc/rc5.d/S97ace-addon
ln -sfn ../init.d/ace-addon /etc/rc0.d/K03ace-addon
ln -sfn ../init.d/ace-addon /etc/rc1.d/K03ace-addon
ln -sfn ../init.d/ace-addon /etc/rc6.d/K03ace-addon

if command -v service >/dev/null 2>&1; then
    service ace-addon restart || service ace-addon start || true
fi

echo "ACE add-on installed."
echo "Configuration:"
echo "  $ADDON_DIR/ace-addon.conf"
echo "Panel:"
echo "  http://<printer-ip>:8091/panel"
