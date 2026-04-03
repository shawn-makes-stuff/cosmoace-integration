# CosmoACE Integration

Standalone Anycubic ACE Pro add-on package for OpenCentauri CosmOS.

This repository is intentionally independent from the full firmware source tree.
It installs on top of an already-running CosmOS printer and does not require a
firmware rebuild.

## What It Installs

- ACE Klipper extra: `/etc/klipper/ace-addon/ace.py`
- Writable Klippy runtime copy: `/etc/klipper/klippy-ace`
- ACE macro/config file: `/etc/klipper/config/ace-user.cfg`
- `printer.cfg` include block for `ace-user.cfg`

## Install (USB + SSH)

1. Copy this folder to a USB drive.
2. SSH into the printer as `root`.
3. Run:

```sh
cd /var/volatile/tmp/usb/sda1/CosmoACE-Integration
chmod +x install.sh uninstall.sh create-package.sh
./install.sh
```

Then set:

- File: `/etc/klipper/config/ace-user.cfg`
- Section: `[ace]`
- Key: `enabled: True`

Restart services:

```sh
service klipper restart
service moonraker restart
```

## Panel Macros (Visible)

- `ACE_PANEL_FEED_SLOT`
- `ACE_PANEL_RETRACT_SLOT`
- `ACE_PANEL_DRY_START`
- `ACE_PANEL_DRY_STOP`

Troubleshooting macro is available but hidden by default:

- `_ACE_PANEL_CONNECTION` (prints `ACE CONNECTED` / `ACE DISCONNECTED`)

## Uninstall

```sh
cd /var/volatile/tmp/usb/sda1/CosmoACE-Integration
./uninstall.sh
```

Uninstall restores the original Klipper init script from:

- `/etc/init.d/klipper.ace-addon.bak`

## Package For Release

```sh
./create-package.sh
```

Output goes to:

- `dist/cosmoace-integration-<timestamp>.tar.gz`
