# Utah configuration for OS-Installer (experimental)

This directory is an OS-Installer distribution config for
[Utah](https://github.com/projectbluefin/utah), from a feasibility spike that
replaces Utah's bootc-installer/fisherman install path with a GNOME OS-style
one:

- The live medium **is** the shipped bootc disk image (`bootc install to-disk`
  at build time). It boots with `ro utah.live`; an initrd unit puts a tmpfs overlay over the root, so the
  session writes to a tmpfs overlay and the medium's partitions stay pristine.
- `scripts/install.sh` block-copies those partitions to the chosen disk with
  `systemd-repart` (`CopyBlocks=`, optionally into LUKS2 with
  `Encrypt=key-file`). It then gives the copies new filesystem UUIDs, rewrites
  the BLS/GRUB/fstab references, removes the live boot entry, grows root and
  adds a firmware boot entry.
- No `bootc install` runs at install time. The copied ostree deployment keeps
  its origin, so `bootc status/upgrade/switch/rollback` work on the result.
- gnome-initial-setup creates the user on first boot (`skip_user: yes`).

## Layout on the live medium

```
/etc/os-installer/config.yaml
/etc/os-installer/utahraptor.png
/etc/os-installer/scripts/install.sh
```

The live session runs `os-installer` as the autologin live user. The install
script re-executes itself through `sudo -n`, which the live overlay allows for
that user only.

## Running the script without the GUI

```
sudo OSI_DEVICE_PATH=/dev/vdb OSI_DEVICE_IS_PARTITION=0 \
     OSI_USE_ENCRYPTION=1 OSI_ENCRYPTION_PIN=... \
     /etc/os-installer/scripts/install.sh
```
