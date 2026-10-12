#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/dist"
STAMP=$(date +%Y%m%d-%H%M%S)
PKG="cosmoace-integration-${STAMP}.tar.gz"

mkdir -p "${DIST_DIR}"

# Package files/ and docs/ wholesale rather than enumerating them: the old
# hand-maintained list drifted out of sync with install.sh's required_files
# twice (the keep-alive pair, then ace_toolhead.cfg), producing tarballs that
# died at install with "Missing files/...".
tar -C "${SCRIPT_DIR}" -czf "${DIST_DIR}/${PKG}" \
    --exclude='__pycache__' \
    install.sh \
    uninstall.sh \
    README.md \
    docs \
    files

echo "Created ${DIST_DIR}/${PKG}"
