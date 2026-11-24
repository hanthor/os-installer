# Utah configuration for OS-Installer (experimental)

The install script in this directory, `scripts/install.sh`, is shared with
[`dakota_config/`](../dakota_config/), whose `scripts` is a symlink to this
directory's `scripts`. See [Dakota](#dakota) for what differs.

This directory is an OS-Installer distribution config for
[Utah](https://github.com/projectbluefin/utah), from a feasibility spike that
replaces Utah's bootc-installer/fisherman install path with a GNOME OS-style
one:

- The live medium **is** the shipped bootc disk image (`bootc install
  to-filesystem` at build time). It boots with `ro utah.live`; an initrd unit puts a tmpfs overlay over the root, so the
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

The Utah spike installs this directory as `/usr/share/utah/os-installer/` and
starts `os-installer --config /usr/share/utah/os-installer/config.yaml` from a
live-only autostart entry. OS-Installer resolves `scripts/install.sh` and the
welcome logo relative to the config's directory.

```
/usr/share/utah/os-installer/config.yaml
/usr/share/utah/os-installer/utahraptor.png
/usr/share/utah/os-installer/scripts/install.sh
```

The live session runs `os-installer` as the autologin live user. The install
script re-executes itself through `sudo -n`, which the live overlay allows for
that user only.

For Utah, the medium needs `/boot` on its own partition (ESP + ext4 `/boot` +
btrfs root): the script encrypts only the root, and GRUB cannot unlock
systemd-repart's LUKS2 (argon2id) to read a `/boot` inside it.

## Dakota

[`dakota_config/`](../dakota_config/) configures the same installer for
[Dakota](https://github.com/projectbluefin/dakota). The script tells the two
apart from the live kernel argument (`utah.live` or `dakota.live`) and from the
medium's partition table and boot entries, so only the branding and live-medium
details differ:

- The live entry boots with `ro dakota.live`, and the live overlay is an extra
  initrd on the ESP. The script removes that entry and initrd from the copy.
- The layout is systemd-boot with ESP + root only: there is no separate
  `/boot`, and the kernels, initrds and Type #1 entries sit on the ESP.
- The config is installed as `/usr/share/dakota/os-installer/`, with `scripts/`
  dereferenced, because `dakota_config/scripts` is a symlink to
  `utah_config/scripts`.

## Install log and firmware boot entry

The script writes its output to the OS-Installer terminal view and appends it to
`/run/utah-install.log` (`/run/dakota-install.log` on Dakota media).

On UEFI machines it also adds a firmware boot entry with `efibootmgr`. Setting
`UTAH_INSTALL_NO_NVRAM` to any non-empty value skips that step and leaves the
firmware boot variables untouched. The script preserves the variable across its
`sudo` re-exec. Without `efibootmgr` the step is skipped as well, and the copied
ESP's removable-media loader (`EFI/BOOT/BOOTX64.EFI`) boots the disk.

## Running the script without the GUI

```
sudo OSI_DEVICE_PATH=/dev/vdb OSI_DEVICE_IS_PARTITION=0 \
     OSI_USE_ENCRYPTION=1 OSI_ENCRYPTION_PIN=... \
     /usr/share/utah/os-installer/scripts/install.sh
```
