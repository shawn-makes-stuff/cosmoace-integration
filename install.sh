#!/bin/sh
# CosmoACE installer for COSMOS firmware (Elegoo Centauri Carbon).
# Run as root on the printer:  sh install.sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ADDON_DIR="/user-resource/ace-addon"
KLIPPER_CONFIG_DIR="/etc/klipper/config"
PRINTER_CFG="${KLIPPER_CONFIG_DIR}/printer.cfg"
MACROS_CFG="${KLIPPER_CONFIG_DIR}/ace-addon.cfg"
BACKUP_DIR="${KLIPPER_CONFIG_DIR}/config-backups"
INCLUDE_LINE="[include ace-addon.cfg]"
SAVE_CONFIG_MARKER='^#\*# <-* SAVE_CONFIG -*>'
STAMP="$(date +%Y%m%d_%H%M%S)"

required_files="files/ace-addon.py files/ace-addon.conf files/ace-command.sh files/ace_macros.cfg files/ace_toolhead.cfg files/ace-keepalive.sh files/ace-keepalive-init"
TOOLHEAD_CFG="${KLIPPER_CONFIG_DIR}/ace_toolhead.cfg"
TOOLHEAD_INCLUDE="[include ace_toolhead.cfg]"
OPTIONS_FILE="${ADDON_DIR}/install_options"

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

# Normalize 0/1 / true/false / yes/no into 0 or 1. Empty -> default.
normalize_bool() {
    raw="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    default="$2"
    case "$raw" in
        "" ) printf '%s' "$default" ;;
        1|y|yes|true|on ) printf '1' ;;
        0|n|no|false|off ) printf '0' ;;
        * ) fail "Invalid boolean '$1' (use 0/1, yes/no, true/false)" ;;
    esac
}

ask_yes_no() {
    # usage: ask_yes_no "Prompt" default(0|1)
    prompt="$1"
    default="$2"
    if [ "$default" = "1" ]; then
        hint="Y/n"
    else
        hint="y/N"
    fi
    printf '%s [%s]: ' "$prompt" "$hint" >&2
    # Non-interactive (no TTY): keep the default.
    if [ ! -t 0 ]; then
        echo "(no TTY, using default ${default})" >&2
        printf '%s' "$default"
        return
    fi
    read -r ans || ans=""
    ans="$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')"
    case "$ans" in
        "" ) printf '%s' "$default" ;;
        y|yes|1|true|on ) printf '1' ;;
        n|no|0|false|off ) printf '0' ;;
        * )
            echo "Unrecognized answer '$ans'; using default ${default}." >&2
            printf '%s' "$default"
            ;;
    esac
}

[ "$(id -u)" -eq 0 ] || fail "Run as root."

for file in $required_files; do
    [ -f "${SCRIPT_DIR}/${file}" ] || fail "Missing ${file} in add-on directory."
done

# --- Hardware options -------------------------------------------------------
# Env vars win (non-interactive): HAS_HUB=1 HAS_TOOLHEAD=1 ./install.sh
# Otherwise prompt on a TTY. Defaults: hub yes, toolhead no (Shawn baseline).
if [ -n "${HAS_HUB+x}" ]; then
    HAS_HUB="$(normalize_bool "${HAS_HUB}" 1)"
else
    HAS_HUB="$(ask_yes_no "Filament hub / chassis runout sensor (PC0 staging)?" 1)"
fi
if [ -n "${HAS_TOOLHEAD+x}" ]; then
    HAS_TOOLHEAD="$(normalize_bool "${HAS_TOOLHEAD}" 0)"
else
    HAS_TOOLHEAD="$(ask_yes_no "Toolhead filament sensor (Canvas/CC1, hotend:PB2)?" 0)"
fi
if [ "$HAS_HUB" = "0" ] && [ "$HAS_TOOLHEAD" = "0" ]; then
    fail "Need at least one of HAS_HUB=1 or HAS_TOOLHEAD=1."
fi
echo "Install options: HAS_HUB=${HAS_HUB} HAS_TOOLHEAD=${HAS_TOOLHEAD}"

# Sanity check: this must be a COSMOS printer.
[ -f "$PRINTER_CFG" ] || fail "${PRINTER_CFG} not found. Is this a COSMOS install?"
[ -x /etc/init.d/klipper ] || fail "/etc/init.d/klipper not found. Is this a COSMOS install?"

# CosmoACE and the built-in AFC/CANVAS support both register T0..T3 and
# fight over toolchanges. Refuse to install alongside it.
if command -v config-manager >/dev/null 2>&1; then
    if [ "$(config-manager extras elegoo_canvas 2>/dev/null || echo False)" = "True" ]; then
        fail "COSMOS 'elegoo_canvas' (AFC/CANVAS) is enabled in cosmos.conf. Disable it before installing CosmoACE."
    fi
fi

# Clean up artifacts from older CosmoACE versions.
rm -f "${KLIPPER_CONFIG_DIR}/klipper-readonly/ace-addon.cfg"   # wiped by COSMOS updates anyway
if [ -f /etc/init.d/ace-addon ]; then
    echo "Removing legacy ace-addon service..."
    /etc/init.d/ace-addon stop 2>/dev/null || true
    rm -f /etc/init.d/ace-addon /etc/rc*.d/S*ace-addon /etc/rc*.d/K*ace-addon
fi

mkdir -p "$ADDON_DIR" "$BACKUP_DIR"

echo "Installing add-on files to ${ADDON_DIR}..."
cp "${SCRIPT_DIR}/files/ace-addon.py" "${ADDON_DIR}/ace-addon.py"
cp "${SCRIPT_DIR}/files/ace-command.sh" "${ADDON_DIR}/ace-command.sh"
cp "${SCRIPT_DIR}/files/ace_macros.cfg" "${ADDON_DIR}/ace_macros.default.cfg"
chmod 0755 "${ADDON_DIR}/ace-addon.py" "${ADDON_DIR}/ace-command.sh"
chmod 0644 "${ADDON_DIR}/ace_macros.default.cfg"

# Keep the uninstaller at a stable path, independent of where this installer
# was run from (USB stick, downloaded tarball, ...).
if [ -f "${SCRIPT_DIR}/uninstall.sh" ]; then
    cp "${SCRIPT_DIR}/uninstall.sh" "${ADDON_DIR}/uninstall.sh"
    chmod 0755 "${ADDON_DIR}/uninstall.sh"
fi

# Keep-alive poller: a shell loop that writes one frame to each ACE every
# 2s, because the ACE drops its USB link ~3.5s after the last frame and that
# would clear feed assist mid-print. Commands still talk to the ACE directly.
echo "Installing ACE keep-alive service..."
cp "${SCRIPT_DIR}/files/ace-keepalive.sh" "${ADDON_DIR}/ace-keepalive.sh"
chmod 0755 "${ADDON_DIR}/ace-keepalive.sh"
cp "${SCRIPT_DIR}/files/ace-keepalive-init" /etc/init.d/ace-keepalive
chmod 0755 /etc/init.d/ace-keepalive
for rl in 2 3 4 5; do
    [ -d "/etc/rc${rl}.d" ] && ln -sf ../init.d/ace-keepalive "/etc/rc${rl}.d/S98ace-keepalive"
done
# Remove the daemon this replaces, if an older install left it behind.
if [ -f /etc/init.d/cosmoace-daemon ]; then
    /etc/init.d/cosmoace-daemon stop 2>/dev/null || true
    rm -f /etc/init.d/cosmoace-daemon /etc/rc*.d/S*cosmoace-daemon /var/run/cosmoace.sock
fi
/etc/init.d/ace-keepalive restart

# Mainsail dashboard panel. On COSMOS builds that ship the Mainsail Panel
# Extender, installing the panel file is all that's needed. On builds
# without it, also install the bundled loader: a union webroot at
# /etc/webui serves patched mainsail entry files plus the addon files
# through moonraker's existing static serving — no system files modified.
if [ ! -d /var/www/mainsail ]; then
    echo "Mainsail not found on this system; skipping the web UI panel."
elif [ -f "${SCRIPT_DIR}/files/webui-panel/panel.js" ]; then
    mkdir -p /user-resource/webui-addons/panels/cosmoace
    cp "${SCRIPT_DIR}/files/webui-panel/panel.js" /user-resource/webui-addons/panels/cosmoace/panel.js
    chmod 0644 /user-resource/webui-addons/panels/cosmoace/panel.js
    if [ -f /var/www/addons/loader.js ]; then
        echo "Web UI panel installed (COSMOS ships the Mainsail Panel Extender)."
    elif [ -f "${SCRIPT_DIR}/files/webui-loader/loader.js" ]; then
        echo "Installing bundled Mainsail panel loader..."
        cp "${SCRIPT_DIR}/files/webui-loader/loader.js" /user-resource/webui-addons/loader.js
        chmod 0644 /user-resource/webui-addons/loader.js
        touch /user-resource/webui-addons/.cosmoace-bundled-loader
        cp "${SCRIPT_DIR}/files/webui-loader/cosmoace-webui-init" /etc/init.d/cosmoace-webui
        chmod 0755 /etc/init.d/cosmoace-webui
        for rl in 2 3 4 5; do
        [ -d "/etc/rc${rl}.d" ] && ln -sf ../init.d/cosmoace-webui "/etc/rc${rl}.d/S97cosmoace-webui"
        done
        /etc/init.d/cosmoace-webui start
        echo "Web UI panel installed (bundled loader). Reload the browser to see it."
    fi
fi

# ace-addon.conf: keep the user's copy unless it has settings that are broken
# on current COSMOS (Moonraker port 7125, toolhead MCU tty, old sensor name) or
# is left over from the daemon build, whose [daemon] section is dead and whose
# pinned serial_port would disable multi-ACE auto-detection.
if [ -f "${ADDON_DIR}/ace-addon.conf" ]; then
    if grep -qE '^[[:space:]]*url[[:space:]]*=.*:7125|^[[:space:]]*serial_port[[:space:]]*=[[:space:]]*/dev/ttyACM0[[:space:]]*$|^[[:space:]]*sensor_name[[:space:]]*=[[:space:]]*runout[[:space:]]*$|^[[:space:]]*\[daemon\]' "${ADDON_DIR}/ace-addon.conf"; then
        echo "Existing ace-addon.conf has settings incompatible with current COSMOS."
        echo "Backing it up to ${ADDON_DIR}/ace-addon.conf.${STAMP}.bak and installing new defaults."
        mv "${ADDON_DIR}/ace-addon.conf" "${ADDON_DIR}/ace-addon.conf.${STAMP}.bak"
        cp "${SCRIPT_DIR}/files/ace-addon.conf" "${ADDON_DIR}/ace-addon.conf"
    else
        echo "Preserving existing ${ADDON_DIR}/ace-addon.conf"
    fi
else
    cp "${SCRIPT_DIR}/files/ace-addon.conf" "${ADDON_DIR}/ace-addon.conf"
fi
chmod 0644 "${ADDON_DIR}/ace-addon.conf"

# Macro config: old versions call M729 (now an emergency stop on COSMOS) and
# the wrong sensor object, so an outdated file must not be preserved as-is.
# (md5sum, not cmp: cmp is not a guaranteed busybox applet on this image.)
# Always re-apply has_hub / has_toolhead after copy so reinstalls honor options.
if [ -f "$MACROS_CFG" ]; then
    if [ "$(md5sum < "${SCRIPT_DIR}/files/ace_macros.cfg")" = "$(md5sum < "$MACROS_CFG")" ]; then
        echo "Macro config already up to date (will still apply HAS_* options)."
    else
        echo "Backing up existing macro config to ${BACKUP_DIR}/ace-addon-${STAMP}.cfg"
        echo "NOTE: re-apply your tuning (e.g. variable_load_to_printhead_mm) to the new ${MACROS_CFG}."
        cp "$MACROS_CFG" "${BACKUP_DIR}/ace-addon-${STAMP}.cfg"
        cp "${SCRIPT_DIR}/files/ace_macros.cfg" "$MACROS_CFG"
    fi
else
    echo "Installing macro config to ${MACROS_CFG}"
    cp "${SCRIPT_DIR}/files/ace_macros.cfg" "$MACROS_CFG"
fi
chmod 0644 "$MACROS_CFG"

# Patch install-time sensor options into the live macro config.
sed -i "s/^variable_has_hub:.*/variable_has_hub: ${HAS_HUB}/" "$MACROS_CFG"
sed -i "s/^variable_has_toolhead:.*/variable_has_toolhead: ${HAS_TOOLHEAD}/" "$MACROS_CFG"
printf 'HAS_HUB=%s\nHAS_TOOLHEAD=%s\n' "$HAS_HUB" "$HAS_TOOLHEAD" > "${OPTIONS_FILE}"
chmod 0644 "${OPTIONS_FILE}"
echo "Wrote ${OPTIONS_FILE}"

# Optional Canvas/CC1 toolhead hardware (only when HAS_TOOLHEAD=1).
if [ "$HAS_TOOLHEAD" = "1" ]; then
    echo "Installing toolhead hardware config to ${TOOLHEAD_CFG}"
    cp "${SCRIPT_DIR}/files/ace_toolhead.cfg" "$TOOLHEAD_CFG"
    chmod 0644 "$TOOLHEAD_CFG"
    if grep -q '^\[include ace_toolhead\.cfg\]' "$PRINTER_CFG"; then
        echo "printer.cfg already includes ace_toolhead.cfg"
    elif grep -q "$SAVE_CONFIG_MARKER" "$PRINTER_CFG"; then
        echo "Adding ${TOOLHEAD_INCLUDE} to printer.cfg (before SAVE_CONFIG block)..."
        awk -v inc="$TOOLHEAD_INCLUDE" '
            /^#\*# <-* SAVE_CONFIG -*>/ && !done { print inc; print ""; done=1 }
            { print }
        ' "$PRINTER_CFG" > "${PRINTER_CFG}.tmp"
        mv "${PRINTER_CFG}.tmp" "$PRINTER_CFG"
    else
        echo "Adding ${TOOLHEAD_INCLUDE} to printer.cfg..."
        printf '\n%s\n' "$TOOLHEAD_INCLUDE" >> "$PRINTER_CFG"
    fi
else
    if [ -f "$TOOLHEAD_CFG" ]; then
        echo "HAS_TOOLHEAD=0: removing ${TOOLHEAD_CFG}"
        rm -f "$TOOLHEAD_CFG"
    fi
    if [ -f "$PRINTER_CFG" ] && grep -q '^\[include ace_toolhead\.cfg\][[:space:]]*$' "$PRINTER_CFG"; then
        echo "HAS_TOOLHEAD=0: removing ace_toolhead.cfg include from printer.cfg"
        sed -i '/^\[include ace_toolhead\.cfg\][[:space:]]*$/d' "$PRINTER_CFG"
    fi
fi

# Wire the macros into printer.cfg. The include must sit before any
# SAVE_CONFIG autosave block, which has to stay at the end of the file.
if grep -q '^\[include ace-addon\.cfg\]' "$PRINTER_CFG"; then
    echo "printer.cfg already includes ace-addon.cfg"
elif grep -q "$SAVE_CONFIG_MARKER" "$PRINTER_CFG"; then
    echo "Adding ${INCLUDE_LINE} to printer.cfg (before SAVE_CONFIG block)..."
    awk -v inc="$INCLUDE_LINE" '
        /^#\*# <-* SAVE_CONFIG -*>/ && !done { print inc; print ""; done=1 }
        { print }
    ' "$PRINTER_CFG" > "${PRINTER_CFG}.tmp"
    mv "${PRINTER_CFG}.tmp" "$PRINTER_CFG"
else
    echo "Adding ${INCLUDE_LINE} to printer.cfg..."
    printf '\n%s\n' "$INCLUDE_LINE" >> "$PRINTER_CFG"
fi

echo "Restarting Klipper..."
/etc/init.d/klipper restart || echo "Warning: Klipper restart failed; restart it manually with: /etc/init.d/klipper restart"

echo ""
echo "CosmoACE installed."
echo "  Addon config:    ${ADDON_DIR}/ace-addon.conf"
echo "  Editable macros: ${MACROS_CFG}"
echo "  Options:         HAS_HUB=${HAS_HUB} HAS_TOOLHEAD=${HAS_TOOLHEAD} (${OPTIONS_FILE})"
echo "  Keep-alive:      /etc/init.d/ace-keepalive (status|restart)"
if [ "$HAS_TOOLHEAD" = "1" ]; then
    echo "  Toolhead cfg:    ${TOOLHEAD_CFG}"
    echo "Tune variable_load_to_toolhead_search_mm / variable_load_past_toolhead_mm in ${MACROS_CFG}."
else
    echo "Tune variable_load_to_printhead_mm in ${MACROS_CFG} for your setup."
fi
echo "Re-run with HAS_TOOLHEAD=1 HAS_HUB=1 to change options non-interactively."
echo "A second chained ACE is auto-detected as slots 5-8 (T4-T7) - no config."
echo "After a COSMOS factory reset, re-run this installer (files in /user-resource survive; /etc does not)."
