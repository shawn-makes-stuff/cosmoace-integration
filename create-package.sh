#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/dist"
STAMP=$(date +%Y%m%d-%H%M%S)
PKG="cosmoace-integration-${STAMP}.tar.gz"

mkdir -p "${DIST_DIR}"

tar -C "${SCRIPT_DIR}" -czf "${DIST_DIR}/${PKG}" \
    install.sh \
    uninstall.sh \
    README.md \
    files/ace-addon.py \
    files/ace-addon.conf \
    files/ace-command.sh \
    files/ace_macros.cfg \

echo "Created ${DIST_DIR}/${PKG}"
