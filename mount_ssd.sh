#!/usr/bin/env bash
# Mount registered USB SSDs at their configured mount points.
# Unregistered SSDs are registered interactively on first sight.
# Portable: needs only bash, util-linux, awk and coreutils.
#
# Usage:
#   sudo bash mount_ssd.sh          # mount all connected SSDs (ask for new ones)
#   sudo bash mount_ssd.sh --edit   # change or delete registrations
#
# Config: mount_ssd.conf next to this script, one "<filesystem UUID> <mount point>" per line.
# The filesystem UUID is stored on the SSD itself, so it is the same on every PC.
# A mount point of "-" means "ignore this filesystem" (never mounted, never asked again).
set -euo pipefail

CONF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mount_ssd.conf"
OWNER="${SUDO_USER:-${DOAS_USER:-}}"
if [[ -z "$OWNER" && -n "${PKEXEC_UID:-}" ]]; then
  OWNER="$(id -nu "$PKEXEC_UID")"
fi
OWNER="${OWNER:-root}"
OWNER_UID="$(id -u "$OWNER")"
OWNER_GID="$(id -g "$OWNER")"

die() { echo "ERROR: $*" >&2; exit 1; }

# --- config helpers -------------------------------------------------------

conf_get() {  # <uuid> -> mount point (empty if not registered)
  [[ -f "$CONF" ]] || return 0
  awk -v id="$1" '$1 !~ /^#/ && $1 == id { print $2; exit }' "$CONF"
}

conf_owner_of() {  # <mount point> -> uuid registered for it (empty if none)
  [[ -f "$CONF" ]] || return 0
  awk -v mp="$1" '$1 !~ /^#/ && $2 == mp { print $1; exit }' "$CONF"
}

conf_write_without() {  # <uuid> [<mount point>]: drop the entry, optionally add a new one
  local tmp
  tmp="$(mktemp)"
  if [[ -f "$CONF" ]]; then
    awk -v id="$1" '$1 != id' "$CONF" > "$tmp"
  fi
  if [[ -n "${2:-}" ]]; then
    echo "$1 $2" >> "$tmp"
  fi
  install -m 644 -o "$OWNER_UID" -g "$OWNER_GID" "$tmp" "$CONF"
  rm -f "$tmp"
}

conf_set() { conf_write_without "$1" "$2"; }
conf_delete() { conf_write_without "$1"; }

# Mount point rules (also applied to hand-edited config values):
# under /mnt/ or /media/, no "." / ".." components, no symlinks below them, no spaces.
# /mnt or /media itself may be a symlink (e.g. ostree systems: /mnt -> var/mnt).
valid_mp() {  # <mount point>
  local mp="$1" top
  [[ "$mp" =~ ^/(mnt|media)(/[A-Za-z0-9._@+-]+)+$ ]] || return 1
  top="/${BASH_REMATCH[1]}"
  [[ ! "$mp" =~ (^|/)\.\.?(/|$) ]] || return 1
  [[ "$(realpath -m "$mp")" == "$(realpath -m "$top")${mp#"$top"}" ]] || return 1
}

# --- device helpers -------------------------------------------------------

# Print "<device> <fstype>" for every mountable partition (or bare disk) on USB disks.
# Containers such as LUKS, LVM, RAID members and swap are skipped.
list_usb_filesystems() {
  local disk tran dev type fstype
  while read -r disk tran; do
    [[ "$tran" == "usb" ]] || continue
    while read -r dev type fstype; do
      [[ "$type" == "part" || "$type" == "disk" ]] || continue
      case "$fstype" in
        ""|crypto_LUKS|swap|bcache|*_member) continue ;;
      esac
      echo "$dev $fstype"
    done < <(lsblk -nrpo NAME,TYPE,FSTYPE "$disk")
  done < <(lsblk -dnrpo NAME,TRAN)
}

fs_uuid() {  # <device> -> filesystem UUID (read from the device, no udev needed)
  blkid -p -s UUID -o value "$1" 2>/dev/null || true
}

trim() { awk '{ $1 = $1 }; 1'; }

describe() {  # <device> -> one-line summary
  local disk
  disk="$(lsblk -nrpo PKNAME "$1" | head -n1)" || true
  [[ -n "$disk" ]] || disk="$1"
  printf '%s  %s  %s  fs=%s label=%s' "$1" \
    "$(lsblk -dno SIZE "$1" | trim)" \
    "$(lsblk -dno MODEL "$disk" | trim)" \
    "$(lsblk -dno FSTYPE "$1" | trim)" \
    "$(lsblk -dno LABEL "$1" | trim)"
}

# Ask for a mount point until a valid one (or empty = skip) is given.
ask_mount_point() {  # <uuid> -> prints mount point, "-" (ignore) or empty (skip)
  local mp other
  while true; do
    read -r -p "  Mount point (e.g. /mnt/data2, empty = skip this time, '-' = always ignore): " mp || return 0
    [[ -z "$mp" ]] && return 0
    if [[ "$mp" == "-" ]]; then echo "-"; return 0; fi
    while [[ "$mp" == */ && "$mp" != "/" ]]; do mp="${mp%/}"; done
    if ! valid_mp "$mp"; then
      echo "  Must be a plain path under /mnt/ or /media/ (no spaces, '..', or symlinks)." >&2
      continue
    fi
    other="$(conf_owner_of "$mp")"
    if [[ -n "$other" && "$other" != "$1" ]]; then
      echo "  Already registered for $other." >&2; continue
    fi
    echo "$mp"
    return 0
  done
}

ask_yes_no() {  # <prompt> -> 0 for yes
  local ans
  read -r -p "$1 [y/N]: " ans || return 1
  [[ "$ans" == [yY]* ]]
}

# Filesystems that store owners (ext4 etc.) keep numeric UIDs, which may differ
# between PCs. Offer to hand the mount point over to the invoking user.
offer_chown() {  # <mount point>
  local mp="$1" cur
  [[ "$OWNER" != "root" ]] || return 0
  cur="$(stat -c %u "$mp")"
  [[ "$cur" != "$OWNER_UID" ]] || return 0
  echo "  $mp is owned by UID $cur, not $OWNER (UID $OWNER_UID)."
  if ask_yes_no "  Change owner of $mp to $OWNER?"; then
    if ask_yes_no "  Also change all files inside (may take long)?"; then
      chown -R "$OWNER_UID:$OWNER_GID" "$mp" || echo "  WARN: chown -R failed." >&2
    else
      chown "$OWNER_UID:$OWNER_GID" "$mp" || echo "  WARN: chown failed." >&2
    fi
  fi
}

# Every step is checked explicitly: this function is called in an `||` context,
# where `set -e` does not apply.
mount_one() {  # <device> <fstype> <mount point>
  local dev="$1" fstype="$2" mp="$3" target opts="nosuid,nodev" real_mp
  # findmnt reports resolved paths (e.g. /var/mnt/data when /mnt is a symlink).
  real_mp="$(realpath -m "$mp")"

  # Release desktop auto-mounts only; leave any other mount alone.
  while read -r target; do
    [[ -n "$target" && "$target" != "$real_mp" ]] || continue
    case "$target" in
      /media/*|/run/media/*)
        echo "  Unmounting auto-mount at $target"
        umount "$target" || { echo "  SKIP: cannot unmount $target (in use?)." >&2; return 1; }
        ;;
      *)
        echo "  SKIP: $dev is also mounted at $target; unmount it first." >&2
        return 1
        ;;
    esac
  done < <(findmnt -n -o TARGET --source "$dev")

  if findmnt -n --source "$dev" --mountpoint "$mp" >/dev/null; then
    echo "  Already mounted: $dev -> $mp"
    return 0
  fi
  if mountpoint -q "$mp"; then
    echo "  SKIP: $mp is already used by another device." >&2
    return 1
  fi
  if [[ -d "$mp" && -n "$(ls -A "$mp")" ]]; then
    echo "  SKIP: $mp is not empty; mounting would hide its files." >&2
    return 1
  fi

  # Filesystems without Unix owners: make the invoking user the owner of all files.
  case "$fstype" in
    vfat|exfat|ntfs|ntfs3) opts="$opts,uid=$OWNER_UID,gid=$OWNER_GID" ;;
  esac

  # blkid reports "ntfs"; without ntfs-3g the kernel's legacy "ntfs" type is read-only,
  # so use the read-write ntfs3 driver explicitly.
  local -a typeopt=()
  if [[ "$fstype" == "ntfs" ]] && ! command -v mount.ntfs-3g >/dev/null \
     && ! command -v mount.ntfs >/dev/null; then
    typeopt=(-t ntfs3)
  fi

  mkdir -p "$mp" || { echo "  SKIP: cannot create $mp." >&2; return 1; }
  mount ${typeopt[@]+"${typeopt[@]}"} -o "$opts" "$dev" "$mp" \
    || { echo "  FAILED: mount $dev -> $mp" >&2; return 1; }
  echo "  Mounted: $dev -> $mp"

  if findmnt -n -o OPTIONS --mountpoint "$mp" | tr ',' '\n' | grep -qx ro; then
    echo "  WARN: $mp was mounted READ-ONLY (write-protected device or missing driver)." >&2
    return 0
  fi

  case "$fstype" in
    vfat|exfat|ntfs|ntfs3) ;;
    *) offer_chown "$mp" ;;
  esac
}

# --- modes ----------------------------------------------------------------

mount_all() {
  local entries entry dev fstype uuid mp failed=0
  local -A seen=()
  mapfile -t entries < <(list_usb_filesystems)
  if [[ ${#entries[@]} -eq 0 ]]; then
    echo "No USB SSD with a mountable filesystem found."
    return 0
  fi

  if [[ "$OWNER" == "root" ]]; then
    echo "WARN: could not determine the invoking user; files will be owned by root." >&2
  fi

  for entry in "${entries[@]}"; do
    read -r dev fstype <<< "$entry"
    describe "$dev" || true; echo
    uuid="$(fs_uuid "$dev")"
    if [[ -z "$uuid" ]]; then
      echo "  SKIP: filesystem has no UUID." >&2
      failed=1; continue
    fi
    if [[ -n "${seen[$uuid]:-}" ]]; then
      if [[ "$fstype" == "btrfs" ]]; then
        # Members of a multi-device btrfs legally share one UUID; mounting one is enough.
        echo "  Member of the btrfs filesystem on ${seen[$uuid]}; nothing to do."
        continue
      fi
      echo "  SKIP: same UUID as ${seen[$uuid]} (cloned disk?). Change one UUID first." >&2
      failed=1; continue
    fi
    seen[$uuid]="$dev"

    mp="$(conf_get "$uuid")"
    if [[ -z "$mp" ]]; then
      echo "  New SSD: UUID=$uuid"
      mp="$(ask_mount_point "$uuid")"
      if [[ -z "$mp" ]]; then
        echo "  Skipped (not registered)."
        continue
      fi
      conf_set "$uuid" "$mp"
      if [[ "$mp" == "-" ]]; then
        echo "  Registered as ignored: $uuid"
        continue
      fi
      echo "  Registered: $uuid -> $mp"
    elif [[ "$mp" == "-" ]]; then
      echo "  Ignored (registered as '-')."
      continue
    elif ! valid_mp "$mp"; then
      echo "  SKIP: invalid mount point '$mp' in $CONF." >&2
      failed=1; continue
    fi
    mount_one "$dev" "$fstype" "$mp" || failed=1
  done
  return "$failed"
}

connected_uuids() {
  local entry dev fstype
  while read -r entry; do
    read -r dev fstype <<< "$entry"
    fs_uuid "$dev"
  done < <(list_usb_filesystems)
}

edit_config() {
  local entries i choice action id mp connected
  while true; do
    mapfile -t entries < <([[ -f "$CONF" ]] && awk '$1 !~ /^#/ && NF >= 2 { print $1, $2 }' "$CONF")
    if [[ ${#entries[@]} -eq 0 ]]; then
      echo "No registered SSDs."
      return 0
    fi
    connected=" $(connected_uuids | tr '\n' ' ') "
    echo "Registered SSDs:"
    for i in "${!entries[@]}"; do
      read -r id mp <<< "${entries[$i]}"
      if [[ "$connected" == *" $id "* ]]; then
        printf '  %d) %s  %s  [connected]\n' "$((i + 1))" "$id" "$mp"
      else
        printf '  %d) %s  %s\n' "$((i + 1))" "$id" "$mp"
      fi
    done
    read -r -p "Number to edit (empty to quit): " choice || return 0
    [[ -z "$choice" ]] && return 0
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#entries[@]} )); then
      echo "Invalid number." >&2; continue
    fi
    read -r id mp <<< "${entries[$((choice - 1))]}"
    read -r -p "  [c]hange mount point / [d]elete / other = cancel: " action || return 0
    case "$action" in
      c)
        mp="$(ask_mount_point "$id")"
        if [[ -n "$mp" ]]; then
          conf_set "$id" "$mp"
          echo "  Updated: $id -> $mp (takes effect on next mount)"
        fi
        ;;
      d)
        conf_delete "$id"
        echo "  Deleted: $id (already-mounted filesystems stay mounted)"
        ;;
    esac
  done
}

[[ $EUID -eq 0 ]] || die "run as root (sudo)."

case "${1:-}" in
  "")     mount_all ;;
  --edit) edit_config ;;
  *)      die "unknown option '$1'. Usage: $0 [--edit]" ;;
esac
