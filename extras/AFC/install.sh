#!/bin/sh
# Install the AFC ACE driver on COSMOS. Run on the printer from this folder:
#   sh install.sh
# Safe to re-run (e.g. after a COSMOS update): the driver and macros are
# replaced, afc-ace.cfg is only written if missing since it holds your
# serial path and tuned bowden length.
set -eu

DIR=$(cd "$(dirname "$0")" && pwd)
CFG=/etc/klipper/config
BASE=/data/afc-ace
STAMP=$(date +%Y%m%d-%H%M%S)

fail() { echo "Error: $*" >&2; exit 1; }

[ -x /etc/init.d/klipper ] || fail "/etc/init.d/klipper not found. Is this a COSMOS install?"
[ "$(config-manager extras elegoo_canvas 2>/dev/null || echo False)" = "True" ] &&
    fail "elegoo_canvas is enabled in cosmos.conf; it loads its own AFC config. Disable it and reboot first."
[ -f /etc/init.d/ace-keepalive ] || [ -f /etc/init.d/ace-addon ] &&
    fail "CosmoACE is installed and would fight this driver for the ACE. Run its uninstall.sh first."

# Strip CR on every copy so a CRLF source tree (Windows scp/USB) cannot
# break BusyBox shebangs or leave stray CRs in gcode.
copy() { sed 's/\r$//' "$1" > "$2"; }

# 1. Writable layer over Klipper's read-only extras, mounted on every boot
copy "$DIR/afc-ace-extras.init" /etc/init.d/afc-ace-extras
chmod 0755 /etc/init.d/afc-ace-extras
for rl in 2 3 4 5; do
    ln -sf ../init.d/afc-ace-extras "/etc/rc${rl}.d/S93afc-ace-extras"
done
/etc/init.d/afc-ace-extras start

# 2. The driver
copy "$DIR/AFC_ACE.py" "$BASE/extras/AFC_ACE.py"

# 3. Config
mkdir -p "$CFG/config-backups"
if [ -f "$CFG/afc-ace.cfg" ]; then
    echo "Keeping existing afc-ace.cfg"
else
    copy "$DIR/afc-ace.cfg" "$CFG/afc-ace.cfg"
fi
[ -f "$CFG/afc-ace-macros.cfg" ] && cp "$CFG/afc-ace-macros.cfg" "$CFG/config-backups/afc-ace-macros.cfg.$STAMP"
copy "$DIR/afc-ace-macros.cfg" "$CFG/afc-ace-macros.cfg"

# 4. Includes, after the COSMOS ones so these sections win. COSMOS's own
# afc.cfg brings [AFC_prep] (PREP at startup) and the BT_* macros.
if ! grep -q "^\[include afc-ace.cfg\]" "$CFG/printer.cfg"; then
    cp "$CFG/printer.cfg" "$CFG/config-backups/printer.cfg.$STAMP"
    sed -i '/^\[include klipper-readonly\/\*\.cfg\]/a\
[include extras-readonly/afc.cfg]\
[include afc-ace.cfg]\
[include afc-ace-macros.cfg]' "$CFG/printer.cfg"
fi

/etc/init.d/klipper restart
echo "Installed. Check the console for PREP output, then run AFC_ACE_STATUS UNIT=ACE_1."
