#!/usr/bin/env bash
# Unmount SSDs registered in mount_ssd.conf (see mount_ssd.sh), then optionally
# power off the USB disks so they can be unplugged safely.
# Portable: needs only bash, util-linux, awk and coreutils.
#
# Usage:
#   sudo bash umount_ssd.sh                  # unmount all mounted registered SSDs
#   sudo bash umount_ssd.sh /mnt/data ...    # unmount only the given mount points
set -euo pipefail

CONF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mount_ssd.conf"

die() { echo "ERROR: $*" >&2; exit 1; }

fs_uuid() {  # <device> -> filesystem UUID
  blkid -p -s UUID -o value "$1" 2>/dev/null || true
}

ask_yes_no() {  # <prompt> -> 0 for yes
  local ans
  read -r -p "$1 [y/N]: " ans || return 1
  [[ "$ans" == [yY]* ]]
}

# Show which processes keep a mount point busy (if fuser is available).
show_users() {  # <mount point>
  if command -v fuser >/dev/null; then
    echo "  Processes using it:" >&2
    fuser -vm "$1" >&2 || true
  else
    echo "  Close files/terminals/file managers using it and retry." >&2
  fi
}

# Unmount one registered entry. Prints the parent disk on success.
umount_one() {  # <uuid> <mount point>
  local uuid="$1" mp="$2" real_mp src disk
  real_mp="$(realpath -m "$mp")"
  # -v: plain device without "[/subvol]" suffix (btrfs subvolumes, bind mounts).
  src="$(findmnt -n -v -o SOURCE --mountpoint "$real_mp" | tail -n1)" || true
  if [[ -z "$src" ]]; then
    echo "  Not mounted: $mp" >&2
    return 0
  fi
  if [[ "$(fs_uuid "$src")" != "$uuid" ]]; then
    echo "  SKIP: $mp holds $src, which is not the registered SSD ($uuid)." >&2
    return 1
  fi
  sync -f "$real_mp" 2>/dev/null || sync
  if ! umount "$real_mp"; then
    echo "  FAILED: cannot unmount $mp (in use?)." >&2
    show_users "$real_mp"
    return 1
  fi
  echo "  Unmounted: $src <- $mp" >&2
  # Walk up to the physical disk (also through LUKS/LVM layers).
  disk="$(lsblk -nrpso NAME,TYPE "$src" 2>/dev/null | awk '$2 == "disk" { print $1; exit }')" || true
  echo "${disk:-$src}"
}

# Detach a USB disk from the kernel so it can be unplugged safely.
power_off() {  # <disk>
  local disk="$1" name part
  if [[ "$(lsblk -dno TRAN "$disk" 2>/dev/null | awk '{ $1 = $1 }; 1')" != "usb" ]]; then
    echo "  $disk is not a USB disk; not offering power-off."
    return 0
  fi
  # Still in use? Mounts and active swap (by device number), open LUKS/LVM/RAID holders,
  # or members of a mounted multi-device btrfs.
  if lsblk -nrpo MOUNTPOINT "$disk" | grep -q .; then
    echo "  $disk still has a mounted filesystem or active swap; not powering off." >&2
    return 0
  fi
  if lsblk -nro TYPE "$disk" | grep -qvxE 'disk|part'; then
    echo "  $disk has active LUKS/LVM/RAID devices; not powering off." >&2
    return 0
  fi
  for part in $(lsblk -nro NAME "$disk"); do
    if compgen -G "/sys/fs/btrfs/*/devices/$part" >/dev/null; then
      echo "  $part is part of a mounted btrfs filesystem; not powering off." >&2
      return 0
    fi
  done
  ask_yes_no "Power off $disk ($(lsblk -dno MODEL "$disk" | awk '{ $1 = $1 }; 1')) for safe removal?" || return 0
  name="$(basename "$disk")"
  if echo 1 > "/sys/block/$name/device/delete"; then
    echo "  Powered off: $disk. You can unplug it now."
  else
    echo "  WARN: could not power off $disk. It is unmounted; unplug when its LED stops blinking." >&2
  fi
}

[[ $EUID -eq 0 ]] || die "run as root (sudo)."
[[ -f "$CONF" ]] || die "config not found: $CONF (run mount_ssd.sh first)."

mapfile -t entries < <(awk '$1 !~ /^#/ && NF >= 2 && $2 != "-" { print $1, $2 }' "$CONF")

# Optional arguments narrow the entries to the given mount points.
if [[ $# -gt 0 ]]; then
  selected=()
  for arg in "$@"; do
    real_arg="$(realpath -m "$arg")"
    found=0
    for entry in ${entries[@]+"${entries[@]}"}; do
      read -r _ mp <<< "$entry"
      if [[ "$(realpath -m "$mp")" == "$real_arg" ]]; then selected+=("$entry"); found=1; fi
    done
    [[ $found -eq 1 ]] || die "$arg is not a registered mount point."
  done
  entries=("${selected[@]}")
fi

failed=0
disks=()
for entry in ${entries[@]+"${entries[@]}"}; do
  read -r uuid mp <<< "$entry"
  echo "$mp"
  if disk="$(umount_one "$uuid" "$mp")"; then
    [[ -n "$disk" ]] && disks+=("$disk")
  else
    failed=1
  fi
done

if [[ ${#disks[@]} -eq 0 ]]; then
  echo "Nothing was unmounted."
else
  for disk in $(printf '%s\n' "${disks[@]}" | sort -u); do
    power_off "$disk"
  done
fi
exit "$failed"
