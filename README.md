# CosmoACE Integration

Standalone Anycubic ACE Pro add-on package for OpenCentauri CosmOS.

This package installs on top of an already-running CosmOS printer. It does not
require a firmware rebuild.

## What It Installs

- ACE service script: `/etc/init.d/ace-addon`
- ACE runtime files: `/user-resource/ace-addon/`
- ACE config: `/user-resource/ace-addon/ace-addon.conf`
- ACE control panel: `/user-resource/ace-addon/ace-panel.html`
- Boot symlinks for the addon service

## Install

1. Copy this repository to a USB drive.
2. SSH into the printer as `root`.
3. Run:

```sh
cd /var/volatile/tmp/usb/sda1/CosmoACE-Integration
chmod +x install.sh uninstall.sh create-package.sh
./install.sh
```

After install, the addon should be available at:

- `http://<printer-ip>:8091/panel`

Default configuration is stored here:

- `/user-resource/ace-addon/ace-addon.conf`

If you need to change the ACE serial port or tuning values, edit that file and
restart the service:

```sh
service ace-addon restart
```

## Controls

The panel exposes:

- Feed / retract for slots 1-4
- Dry start / dry stop
- Serial auto-detect and health/status probes

## Uninstall

```sh
cd /var/volatile/tmp/usb/sda1/CosmoACE-Integration
./uninstall.sh
```

## Package For Release

```sh
./create-package.sh
```

Output goes to:

- `dist/cosmoace-integration-<timestamp>.tar.gz`
