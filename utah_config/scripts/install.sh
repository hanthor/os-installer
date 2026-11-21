#!/usr/bin/env bash
# Utah install script for OS-Installer: GNOME OS-style "copy the image" install.
#
# The live session runs from the very disk image it installs: a bootc
# `install to-disk` image booted with `utah.live systemd.volatile=overlay ro`,
# so every write lands in a tmpfs overlay and the medium's partitions stay
# byte-for-byte what the build produced. Installing is therefore a block copy
# of those partitions (systemd-repart CopyBlocks=, optionally into LUKS2),
# followed by the per-machine fixups a raw copy cannot get right by itself:
#
#   * new filesystem UUIDs/serials (the live medium may stay plugged in), and
#     every boot-config reference to the old ones rewritten (BLS entries,
#     bootupd's GRUB configs, the deployment's /etc/fstab);
#   * the live boot entry and its GRUB default removed, so the installed system
#     never boots with utah.live;
#   * rd.luks.uuid on the ostree BLS entries and an /etc/crypttab line when the
#     root is encrypted;
#   * the root filesystem grown to the partition;
#   * a firmware boot entry for shim on UEFI machines.
#
# The ostree deployment, its origin (container-image-reference), SELinux labels
# and the empty /etc/machine-id are part of the copied blocks, so bootc
# status/upgrade/switch/rollback work unchanged on the installed disk.
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
# OS-Installer shows this output in its terminal view; keep a copy for support.
exec > >(tee -a /run/utah-install.log) 2>&1
install_start=$(date +%s)
printf '==> %s Utah install started\n' "$(date -Is)"

log() { printf '==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

LIVE_ENTRY=utah-live
ROOT_TYPE_X86_64=4f68bce3-e8cd-4db1-96e7-fbcaf984b709
BIOS_BOOT_TYPE=21686148-6449-6e6f-744e-656564454649
ESP_TYPE=c12a7328-f81f-11d2-ba4b-00a0c93ec93b

target="${OSI_DEVICE_PATH:?OSI_DEVICE_PATH is required}"
[[ "${OSI_DEVICE_IS_PARTITION:-0}" == 0 ]] || fail "installing into a partition is not supported; choose a whole disk"
[[ -b "${target}" ]] || fail "${target} is not a block device"
encrypt="${OSI_USE_ENCRYPTION:-0}"
if [[ "${encrypt}" == 1 && -z "${OSI_ENCRYPTION_PIN:-}" ]]; then
    fail "encryption requested without a passphrase"
fi

grep -qw utah.live /proc/cmdline || fail "not running from Utah live media (no utah.live on the kernel command line)"

# --- Locate the medium: the disk that holds the booted root filesystem. ------
root_uuid="$(sed -n 's/.*\broot=UUID=\([^ ]*\).*/\1/p' /proc/cmdline)"
[[ -n "${root_uuid}" ]] || fail "no root=UUID= on the kernel command line"
target_name="$(basename "$(realpath "${target}")")"
mapfile -t sources < <(lsblk -rnpo NAME,UUID,PKNAME | awk -v u="${root_uuid}" -v t="/dev/${target_name}" '$2 == u && $3 != t { print $1 " " $3 }')
[[ ${#sources[@]} -eq 1 ]] || fail "expected exactly one live root partition with UUID ${root_uuid}, found ${#sources[@]}"
src_root_part="${sources[0]% *}"
src_disk="${sources[0]#* }"
[[ "$(realpath "${src_disk}")" != "$(realpath "${target}")" ]] || fail "refusing to install onto the live medium itself"
log "Live medium ${src_disk} (root ${src_root_part}); target ${target}"

work="$(mktemp -d /run/utah-install.XXXXXX)"
mapper="utah-install-root-$$"
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
target_parts=()
mapfile -t target_parts < <(lsblk -rnpo NAME,TYPE "${target}" | awk '$2 == "part" { print $1 }')
esp="" boot="" root_part=""
for p in "${target_parts[@]}"; do
    ptype="$(lsblk -rno PARTTYPE "$p" | tr '[:upper:]' '[:lower:]')"
    if [[ "${ptype}" == "${ESP_TYPE}" ]]; then
        esp="$p"
    elif [[ "${ptype}" == "${ROOT_TYPE_X86_64}" ]] || { [[ "${encrypt}" == 1 ]] && blkid -p -s TYPE -o value "$p" | grep -qx crypto_LUKS; }; then
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

mapfile -t deployments < <(find "${work}/mnt/root/ostree/deploy" -mindepth 3 -maxdepth 3 -type d -path '*/deploy/*' ! -name '*.origin')
[[ ${#deployments[@]} -ge 1 ]] || fail "no ostree deployment on the copied root"
for d in "${deployments[@]}"; do
    mid="$(cat "$d/etc/machine-id" 2>/dev/null || true)"
    [[ -z "${mid}" || "${mid}" == uninitialized ]] || fail "the medium carries a machine-id (${mid}); it was booted read-write and is not pristine"
done

files=()
shopt -s nullglob
files+=("${bootdir}"/loader/entries/*.conf "${bootdir}"/grub2/*.cfg)
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

rm -f "${bootdir}/loader/entries/${LIVE_ENTRY}.conf"
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
if grep -rqw utah.live "${bootdir}/loader/entries/"; then
    fail "a boot entry still carries utah.live"
fi

if [[ "${encrypt}" == 1 ]]; then
    for entry in "${bootdir}"/loader/entries/*.conf; do
        sed -i "/^options /{/rd.luks.uuid=${luks_uuid}/!s/\$/ rd.luks.uuid=${luks_uuid}/}" "${entry}"
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

for entry in "${bootdir}"/loader/entries/*.conf; do
    log "boot entry ${entry##*/}: $(sed -n 's/^options //p' "${entry}")"
done

shim=""
if [[ -n "${esp}" ]]; then
    for candidate in "${work}"/mnt/efi/EFI/*/shimx64.efi; do
        [[ -f "${candidate}" ]] && { shim="${candidate#"${work}"/mnt/efi}"; break; }
    done
fi
sync
umount -R "${work}/mnt/efi" 2>/dev/null || true
umount -R "${work}/mnt/boot" 2>/dev/null || true
umount -R "${work}/mnt/root"
[[ "${encrypt}" == 1 ]] && cryptsetup close "${mapper}"

if [[ -n "${shim}" && -d /sys/firmware/efi/efivars && -z "${UTAH_INSTALL_NO_NVRAM:-}" ]]; then
    partnum="$(lsblk -rno PARTN "${esp}")"
    efibootmgr --create --disk "${target}" --part "${partnum}" --label Utah \
        --loader "$(tr / '\\' <<<"${shim}")" >/dev/null
    log "firmware boot entry: Utah -> ${shim}"
fi
log "Utah installed to ${target} in $(( $(date +%s) - install_start ))s"
