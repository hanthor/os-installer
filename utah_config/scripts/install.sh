#!/usr/bin/env bash
# Utah and Dakota install script for OS-Installer: GNOME OS-style "copy the
# image" install. One script serves both distributions; what differs is
# read from the medium (its partition table, boot entries and root
# filesystem), and branding stays in each distribution's config.yaml.
#
# The live session runs from the very disk image it installs: a bootc
# `install to-disk`/`to-filesystem` image booted from its live entry
# (`ro utah.live` or `ro dakota.live`, an initrd tmpfs overlay over its root),
# so every write lands in a tmpfs overlay and the medium's partitions stay
# byte-for-byte what the build produced. Installing is therefore a block copy
# of those partitions (systemd-repart CopyBlocks=, optionally into LUKS2),
# followed by the per-machine fixups a raw copy cannot get right by itself:
#
#   * new filesystem UUIDs/serials (the live medium may stay plugged in), and
#     every boot-config reference to the old ones rewritten (BLS entries in
#     /boot or on the ESP and their systemd.mount-extra /boot karg, bootupd's
#     GRUB configs, the deployment's /etc/fstab); a root=LABEL= karg becomes
#     root=UUID=, because medium and copy share the label;
#   * the live boot entry, the initrds only it loads, and its GRUB
#     (grubenv saved_entry) or systemd-boot (loader.conf default) default
#     removed, so the installed system never boots with the live karg;
#   * rd.luks.uuid on the deployment's BLS entries and an /etc/crypttab line when the
#     root is encrypted;
#   * the root filesystem grown to the partition;
#   * a firmware boot entry for shim (or systemd-boot) on UEFI machines.
#
# The deployment, its origin (container-image-reference), SELinux labels and
# the empty /etc/machine-id are part of the copied blocks, so bootc
# status/upgrade/switch/rollback work unchanged on the installed disk. Both
# bootc backends are handled: ostree (/ostree/deploy/<stateroot>/deploy/<id>)
# and composefs (/composefs repository, /state/deploy/<verity digest> with the
# deployment's etc and origin, BLS entries with a composefs= karg). A raw copy
# keeps composefs's fs-verity: it lives in the filesystem metadata (btrfs
# items, ext4 blocks past EOF) that the copy carries and that the UUID change
# only re-stamps. The installed entries keep the strict composefs= karg.
#
# Layouts seen so far: Utah (GRUB/bootupd, ESP + ext4 /boot + btrfs root,
# entries in /boot/loader/entries) and Dakota (systemd-boot, ESP + root,
# Type #1 entries, kernels and initrds on the ESP, loader/loader.conf).
#
# User creation is deliberately absent: gnome-initial-setup runs on first boot
# (config.yaml skip_user/skip_region).
#
# Environment (OS-Installer install phase): OSI_DEVICE_PATH,
# OSI_DEVICE_IS_PARTITION, OSI_USE_ENCRYPTION, OSI_ENCRYPTION_PIN. All other
# OSI_* variables are accepted and ignored.
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
    exec sudo -n --preserve-env=OSI_DEVICE_PATH,OSI_DEVICE_IS_PARTITION,OSI_USE_ENCRYPTION,OSI_ENCRYPTION_PIN,UTAH_INSTALL_NO_NVRAM "$0" "$@"
fi

# The live karg names the distribution: its log, live entry and messages.
read -r -a cmdline </proc/cmdline
distro=""
for arg in "${cmdline[@]}"; do
    case "${arg}" in
        utah.live) distro=Utah ;;
        dakota.live) distro=Dakota ;;
    esac
done
[[ -n "${distro}" ]] || { echo "ERROR: not running from live media (no utah.live or dakota.live on the kernel command line)" >&2; exit 1; }
distro_id="${distro,,}"
LIVE_KARG="${distro_id}.live"
LIVE_ENTRY="${distro_id}-live"

# OS-Installer shows this output in its terminal view; keep a copy for support.
exec > >(tee -a "/run/${distro_id}-install.log") 2>&1
install_start=$(date +%s)
printf '==> %s %s install started\n' "$(date -Is)" "${distro}"

log() { printf '==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

BIOS_BOOT_TYPE=21686148-6449-6e6f-744e-656564454649
ESP_TYPE=c12a7328-f81f-11d2-ba4b-00a0c93ec93b

target="${OSI_DEVICE_PATH:?OSI_DEVICE_PATH is required}"
[[ "${OSI_DEVICE_IS_PARTITION:-0}" == 0 ]] || fail "installing into a partition is not supported; choose a whole disk"
[[ -b "${target}" ]] || fail "${target} is not a block device"
encrypt="${OSI_USE_ENCRYPTION:-0}"
if [[ "${encrypt}" == 1 && -z "${OSI_ENCRYPTION_PIN:-}" ]]; then
    fail "encryption requested without a passphrase"
fi

# --- Locate the medium: the disk that holds the booted root filesystem. ------
# root=UUID= (bootc's default) or root=LABEL=; the target is excluded, so a
# label shared with an earlier install on it does not count.
root_spec=""
for arg in "${cmdline[@]}"; do
    case "${arg}" in root=UUID=*|root=LABEL=*) root_spec="${arg#root=}" ;; esac
done
[[ -n "${root_spec}" ]] || fail "no root=UUID= or root=LABEL= on the kernel command line"
target_name="$(basename "$(realpath "${target}")")"
# PKNAME first: lsblk -r leaves empty columns empty, and awk would shift every
# later field (partitions always have a parent; labelled filesystems a UUID).
mapfile -t sources < <(lsblk -rnpo NAME,PKNAME,UUID,LABEL | awk -v k="${root_spec%%=*}" -v v="${root_spec#*=}" -v t="/dev/${target_name}" \
    '((k == "UUID" && $3 == v) || (k == "LABEL" && $4 == v)) && $2 != t { print $1 " " $2 }')
[[ ${#sources[@]} -eq 1 ]] || fail "expected exactly one live root partition with ${root_spec}, found ${#sources[@]}"
src_root_part="${sources[0]% *}"
src_disk="${sources[0]#* }"
[[ "$(realpath "${src_disk}")" != "$(realpath "${target}")" ]] || fail "refusing to install onto the live medium itself"
log "Live medium ${src_disk} (root ${src_root_part}); target ${target}"

work="$(mktemp -d "/run/${distro_id}-install.XXXXXX")"
mapper="${distro_id}-install-root-$$"
cleanup() {
    set +e
    for m in "${work}"/mnt/*; do mountpoint -q "$m" && umount -R "$m"; done
    [[ -e "/dev/mapper/${mapper}" ]] && cryptsetup close "${mapper}"
    rm -rf "${work}"
}
trap cleanup EXIT
mkdir -p "${work}/repart.d" "${work}/mnt"

# --- Partition definitions mirroring the medium. -----------------------------
# Every medium partition is copied block for block at its own size, except the
# root partition, which takes the rest of the target disk. The BIOS boot
# partition is skipped: Utah media are UEFI-only, and GRUB's BIOS core image
# would also need the MBR boot code and its own sector map.
sfdisk --json "${src_disk}" >"${work}/medium.json"
python3 - "${work}/medium.json" "${work}/repart.d" "${src_root_part}" "${encrypt}" "${BIOS_BOOT_TYPE}" <<'PY'
import json, pathlib, sys
table = json.load(open(sys.argv[1]))["partitiontable"]
out, root_node, encrypt, bios = pathlib.Path(sys.argv[2]), sys.argv[3], sys.argv[4] == "1", sys.argv[5]
sector = table.get("sectorsize", 512)
for index, part in enumerate(table["partitions"], start=1):
    ptype = part["type"].lower()
    if ptype == bios:
        continue
    size = part["size"] * sector
    lines = ["[Partition]", f"Type={ptype}", f"CopyBlocks={part['node']}"]
    if part.get("name"):
        lines.append(f"Label={part['name']}")
    if part["node"] == root_node:
        # LUKS2 needs room for its header on top of the copied filesystem.
        lines.append(f"SizeMinBytes={size + (32 << 20) if encrypt else size}")
        if encrypt:
            lines.append("Encrypt=key-file")
    else:
        lines += [f"SizeMinBytes={size}", f"SizeMaxBytes={size}"]
    (out / f"{index:02d}-copy.conf").write_text("\n".join(lines) + "\n")
PY
for f in "${work}"/repart.d/*.conf; do log "$(basename "$f"): $(tr '\n' ' ' <"$f")"; done

repart_args=(--dry-run=no --empty=force --offline=no --seed=random --definitions="${work}/repart.d")
key="${work}/luks.key"
if [[ "${encrypt}" == 1 ]]; then
    printf '%s' "${OSI_ENCRYPTION_PIN}" >"${key}"
    chmod 0400 "${key}"
    repart_args+=(--key-file="${key}")
fi
wipefs --all --quiet "${target}"
log "Copying the image with systemd-repart"
start=$(date +%s)
systemd-repart "${repart_args[@]}" "${target}"
udevadm settle
log "Block copy finished in $(( $(date +%s) - start ))s"

# --- Identify the new partitions. --------------------------------------------
# The copy keeps each partition's type: the root is the one with the medium
# root's type (Utah: root-x86-64; Dakota: whatever bootc to-disk chose), or
# the LUKS2 container.
src_root_type="$(lsblk -rno PARTTYPE "${src_root_part}" | tr '[:upper:]' '[:lower:]')"
target_parts=()
mapfile -t target_parts < <(lsblk -rnpo NAME,TYPE "${target}" | awk '$2 == "part" { print $1 }')
esp="" boot="" root_part=""
for p in "${target_parts[@]}"; do
    ptype="$(lsblk -rno PARTTYPE "$p" | tr '[:upper:]' '[:lower:]')"
    if [[ "${ptype}" == "${ESP_TYPE}" ]]; then
        esp="$p"
    elif [[ "${ptype}" == "${src_root_type}" ]] || { [[ "${encrypt}" == 1 ]] && blkid -p -s TYPE -o value "$p" | grep -qx crypto_LUKS; }; then
        root_part="$p"
    elif [[ "$(blkid -p -s TYPE -o value "$p")" == ext4 ]]; then
        boot="$p"
    fi
done
[[ -n "${root_part}" ]] || fail "could not find the copied root partition on ${target}"
log "Target ESP=${esp:-none} boot=${boot:-none} root=${root_part}"

root_dev="${root_part}"
luks_uuid=""
if [[ "${encrypt}" == 1 ]]; then
    luks_uuid="$(cryptsetup luksUUID "${root_part}")"
    cryptsetup open --key-file "${key}" "${root_part}" "${mapper}"
    root_dev="/dev/mapper/${mapper}"
fi

# --- Give every copied filesystem a new identity. ----------------------------
declare -A uuid_map
new_fs_uuid() {
    local dev="$1" fstype old new
    fstype="$(blkid -p -s TYPE -o value "${dev}")"
    old="$(blkid -p -s UUID -o value "${dev}")"
    case "${fstype}" in
        vfat)
            new="$(python3 - "${dev}" <<'PY'
import os, struct, sys
dev = sys.argv[1]
serial = struct.unpack("<I", os.urandom(4))[0]
with open(dev, "r+b") as f:
    bs = bytearray(f.read(512))
    fat32 = bs[82:90] == b"FAT32   "
    off = 0x43 if fat32 else 0x27
    bs[off:off + 4] = struct.pack("<I", serial)
    f.seek(0); f.write(bs)
    if fat32:
        bytes_per_sector = struct.unpack("<H", bs[11:13])[0]
        backup = struct.unpack("<H", bs[50:52])[0]
        if backup:
            f.seek(backup * bytes_per_sector + off); f.write(struct.pack("<I", serial))
print("%04X-%04X" % (serial >> 16, serial & 0xFFFF))
PY
)" ;;
        ext4|ext3|ext2)
            e2fsck -fy "${dev}" >/dev/null || [[ $? -le 1 ]] || fail "e2fsck failed on ${dev}"
            tune2fs -U random "${dev}" >/dev/null ;;
        btrfs)
            btrfstune -f -u "${dev}" >/dev/null ;;
        xfs)
            xfs_admin -U generate "${dev}" >/dev/null ;;
        *) fail "unsupported filesystem ${fstype:-unknown} on ${dev}" ;;
    esac
    udevadm settle
    [[ -n "${new:-}" ]] || new="$(blkid -p -s UUID -o value "${dev}")"
    [[ -n "${old}" && -n "${new}" && "${old}" != "${new}" ]] || fail "UUID change on ${dev} did not take (${old} -> ${new})"
    uuid_map["${old}"]="${new}"
    log "${dev} (${fstype}): ${old} -> ${new}"
}
[[ -n "${esp}" ]] && new_fs_uuid "${esp}"
[[ -n "${boot}" ]] && new_fs_uuid "${boot}"
new_fs_uuid "${root_dev}"

# --- Mount and fix up the copied boot configuration. -------------------------
mkdir -p "${work}/mnt/root" "${work}/mnt/boot" "${work}/mnt/efi"
mount "${root_dev}" "${work}/mnt/root"
bootdir="${work}/mnt/root/boot"
if [[ -n "${boot}" ]]; then
    mount "${boot}" "${work}/mnt/boot"
    bootdir="${work}/mnt/boot"
fi
[[ -n "${esp}" ]] && mount "${esp}" "${work}/mnt/efi"

# ostree: <stateroot>/deploy/<checksum>.<serial> (a find on '*/deploy/*' would
# also match <stateroot>/var/* through the ostree/deploy prefix). composefs:
# state/deploy/<verity digest>, holding the deployment's etc/ and .origin.
deployments=()
for d in "${work}"/mnt/root/ostree/deploy/*/deploy/* "${work}"/mnt/root/state/deploy/*; do
    [[ -d "$d/etc" ]] && deployments+=("$d")
done
[[ ${#deployments[@]} -ge 1 ]] || fail "no ostree or composefs deployment on the copied root"
log "deployments: ${deployments[*]#"${work}"/mnt/root/}"
for d in "${deployments[@]}"; do
    mid="$(cat "$d/etc/machine-id" 2>/dev/null || true)"
    [[ -z "${mid}" || "${mid}" == uninitialized ]] || fail "the medium carries a machine-id (${mid}); it was booted read-write and is not pristine"
done

# Boot entries: /boot/loader/entries (Utah, GRUB's blscfg) and, with
# systemd-boot, Type #1 entries on the ESP next to the kernels and initrds
# they load (Dakota; there is no separate /boot).
entry_dirs=("${bootdir}/loader/entries")
[[ -n "${esp}" && -d "${work}/mnt/efi/loader/entries" ]] && entry_dirs+=("${work}/mnt/efi/loader/entries")
files=()
shopt -s nullglob
for dir in "${entry_dirs[@]}"; do files+=("${dir}"/*.conf); done
files+=("${bootdir}"/grub2/*.cfg)
[[ -n "${esp}" ]] && files+=("${work}"/mnt/efi/EFI/*/*.cfg)
for d in "${deployments[@]}"; do [[ -f "$d/etc/fstab" ]] && files+=("$d/etc/fstab"); done
shopt -u nullglob
for old in "${!uuid_map[@]}"; do
    for f in "${files[@]}"; do
        if grep -qF -- "${old}" "$f"; then
            sed -i "s/${old}/${uuid_map[${old}]}/g" "$f"
            log "rewrote ${old} in ${f#"${work}"/mnt/}"
        fi
    done
done
# A label names the medium and the copy alike: pin the copy's root by UUID.
root_fs_uuid="$(blkid -p -s UUID -o value "${root_dev}")"
for f in "${files[@]}"; do
    if grep -q '\broot=LABEL=' "$f"; then
        sed -i "s/\broot=LABEL=[^ ]*/root=UUID=${root_fs_uuid}/g" "$f"
        log "root=LABEL= -> root=UUID=${root_fs_uuid} in ${f#"${work}"/mnt/}"
    fi
done

# The live entry goes, and so do the initrds only it loads (Dakota's live
# overlay ships as an extra initrd on the ESP); then its default.
for dir in "${entry_dirs[@]}"; do
    live="${dir}/${LIVE_ENTRY}.conf"
    [[ -f "${live}" ]] || continue
    top="$(dirname "$(dirname "${dir}")")"
    mapfile -t live_initrds < <(awk '$1 == "initrd" { print $2 }' "${live}")
    rm -f "${live}"
    shopt -s nullglob
    others=("${dir}"/*.conf)
    shopt -u nullglob
    for path in "${live_initrds[@]}"; do
        (( ${#others[@]} )) && awk -v p="${path}" '$1 == "initrd" && $2 == p { found = 1 } END { exit !found }' "${others[@]}" && continue
        [[ -f "${top}${path}" ]] || continue
        rm -f "${top}${path}"
        rmdir --ignore-fail-on-non-empty "$(dirname "${top}${path}")"
        log "removed live-only initrd ${path}"
    done
done
if [[ -f "${bootdir}/grub2/grubenv" ]]; then
    python3 - "${bootdir}/grub2/grubenv" "${LIVE_ENTRY}" <<'PY'
import sys
path, live = sys.argv[1], sys.argv[2]
lines = [l for l in open(path).read().split("\n") if l and not l.startswith("#")]
keep = [l for l in lines if l != f"saved_entry={live}"]
body = "# GRUB Environment Block\n" + "".join(l + "\n" for l in keep)
open(path, "w").write(body + "#" * (1024 - len(body)))
PY
fi
loader_conf="${work}/mnt/efi/loader/loader.conf"
if [[ -n "${esp}" && -f "${loader_conf}" ]] && grep -qE "^default[[:space:]]+${LIVE_ENTRY}(\.conf)?[[:space:]]*$" "${loader_conf}"; then
    sed -i -E "/^default[[:space:]]+${LIVE_ENTRY}(\.conf)?[[:space:]]*$/d" "${loader_conf}"
    log "loader.conf: live default removed"
fi
for dir in "${entry_dirs[@]}"; do
    if grep -rqw "${LIVE_KARG}" "${dir}/" 2>/dev/null; then
        fail "a boot entry still carries ${LIVE_KARG}"
    fi
done

if [[ "${encrypt}" == 1 ]]; then
    for dir in "${entry_dirs[@]}"; do
        for entry in "${dir}"/*.conf; do
            [[ -f "${entry}" ]] || continue
            sed -i "/^options /{/rd.luks.uuid=${luks_uuid}/!s/\$/ rd.luks.uuid=${luks_uuid}/}" "${entry}"
        done
    done
    for d in "${deployments[@]}"; do
        printf 'luks-%s UUID=%s none discard\n' "${luks_uuid}" "${luks_uuid}" >"$d/etc/crypttab"
    done
    log "root is LUKS2 ${luks_uuid}"
fi

case "$(blkid -p -s TYPE -o value "${root_dev}")" in
    btrfs) btrfs filesystem resize max "${work}/mnt/root" >/dev/null ;;
    ext4) resize2fs "${root_dev}" >/dev/null ;;
    xfs) xfs_growfs "${work}/mnt/root" >/dev/null ;;
esac
log "root filesystem grown: $(df -h --output=size "${work}/mnt/root" | tail -1 | tr -d ' ')"

for dir in "${entry_dirs[@]}"; do
    for entry in "${dir}"/*.conf; do
        [[ -f "${entry}" ]] && log "boot entry ${entry##*/}: $(sed -n 's/^options //p' "${entry}")"
    done
done
[[ -f "${loader_conf}" ]] && log "loader.conf: $(grep -v '^#' "${loader_conf}" | tr '\n' ' ')"

# shim when the ESP has one (Utah; Dakota after dakota-secure-boot enroll),
# else systemd-boot as bootctl installed it.
loader=""
if [[ -n "${esp}" ]]; then
    for candidate in "${work}"/mnt/efi/EFI/*/shimx64.efi "${work}"/mnt/efi/EFI/systemd/systemd-bootx64.efi; do
        [[ -f "${candidate}" ]] && { loader="${candidate#"${work}"/mnt/efi}"; break; }
    done
fi
sync
umount -R "${work}/mnt/efi" 2>/dev/null || true
umount -R "${work}/mnt/boot" 2>/dev/null || true
umount -R "${work}/mnt/root"
[[ "${encrypt}" == 1 ]] && cryptsetup close "${mapper}"

if [[ -n "${loader}" && -d /sys/firmware/efi/efivars && -z "${UTAH_INSTALL_NO_NVRAM:-}" ]]; then
    partnum="$(lsblk -rno PARTN "${esp}")"
    if command -v efibootmgr >/dev/null; then
        efibootmgr --create --disk "${target}" --part "${partnum}" --label "${distro}" \
            --loader "$(tr / '\\' <<<"${loader}")" >/dev/null
        log "firmware boot entry: ${distro} -> ${loader}"
    else
        log "no efibootmgr: the copied ESP's removable-media loader (EFI/BOOT/BOOTX64.EFI) boots the disk"
    fi
fi
log "${distro} installed to ${target} in $(( $(date +%s) - install_start ))s"
