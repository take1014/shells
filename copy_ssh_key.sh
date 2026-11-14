#!/usr/bin/env bash
# Copy one of your SSH public keys (~/.ssh/*.pub) to user@host interactively.
# Only public keys are ever sent; private keys never leave this PC.
# Portable: needs bash, OpenSSH client (ssh, ssh-keygen, ssh-copy-id), awk and coreutils. No root.
#
# Usage:
#   bash copy_ssh_key.sh
set -euo pipefail

SSH_DIR="$HOME/.ssh"
ME="${USER:-$(id -un)}"

die() { echo "ERROR: $*" >&2; exit 1; }

for cmd in ssh ssh-keygen ssh-copy-id; do
  command -v "$cmd" >/dev/null || die "required command not found: $cmd"
done

# True only if every line of the file is a public key ("<type> <base64> [comment]"),
# so a private key that was saved under a .pub name is never sent.
is_public_key() {  # <file>
  awk 'NF && !/^(ssh-|ecdsa-|sk-)[A-Za-z0-9@.-]+ [A-Za-z0-9+\/]+=*( |$)/ { bad = 1 }
       NF { n++ }
       END { exit (bad || !n) }' "$1"
}

ask_yes_no() {  # <prompt> -> 0 for yes
  local ans
  read -r -p "$1 [y/N]: " ans || return 1
  [[ "$ans" == [yY]* ]]
}

# --- choose a key ---------------------------------------------------------

# A key is usable only with its private half: ssh-copy-id logs in with it to skip
# keys that are already installed, and you could not log in with it from here anyway.
keys=()
shopt -s nullglob
for pub in "$SSH_DIR"/*.pub; do
  if ! is_public_key "$pub"; then
    echo "Skipping $pub (not a public key)." >&2
  elif [[ -f "${pub%.pub}" ]]; then
    keys+=("$pub")
  else
    echo "Skipping $pub (no matching private key)." >&2
  fi
done
shopt -u nullglob
(( ${#keys[@]} > 0 )) || die "no key pair in $SSH_DIR. Create one with: ssh-keygen -t ed25519"

echo "Public keys in $SSH_DIR:"
for i in "${!keys[@]}"; do
  # ssh-keygen -l prints "<bits> <fingerprint> <comment> (<type>)".
  printf '  %d) %s  %s\n' "$((i + 1))" "$(basename "${keys[$i]}")" \
    "$(ssh-keygen -lf "${keys[$i]}" 2>/dev/null || echo '(unreadable)')"
done

while :; do
  read -r -p "Key number [1]: " choice || exit 1
  choice="${choice:-1}"
  if [[ "$choice" =~ ^[0-9]+$ ]] && (( 10#$choice >= 1 && 10#$choice <= ${#keys[@]} )); then
    key="${keys[$((10#$choice - 1))]}"
    break
  fi
  echo "Invalid number." >&2
done

# --- copy to one or more hosts --------------------------------------------

while :; do
  read -r -p "Target (user@host, or host for user '$ME'; empty to quit): " target || exit 0
  [[ -n "$target" ]] || exit 0
  [[ "$target" == *@* ]] || target="$ME@$target"
  if [[ ! "$target" =~ ^[A-Za-z0-9._][A-Za-z0-9._-]*@[A-Za-z0-9._%:-]+$ ]]; then
    echo "Invalid target '$target' (expected e.g. pi@192.168.1.20)." >&2
    continue
  fi
  # Exactly one ':' is "host:port", not IPv6; the port is asked separately.
  if [[ "${target#*@}" =~ ^[^:]*:[^:]*$ ]]; then
    echo "Invalid target '$target': enter the port at the next prompt, not after ':'." >&2
    continue
  fi

  read -r -p "SSH port [22]: " port || exit 1
  port="${port:-22}"
  if [[ ! "$port" =~ ^[0-9]+$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
    echo "Invalid port '$port'." >&2
    continue
  fi
  port=$(( 10#$port ))

  echo "Copying $(basename "$key") to $target (port $port). You may be asked for $target's password."
  if ! ssh-copy-id -i "$key" -p "$port" "$target"; then
    echo "FAILED: could not copy the key to $target." >&2
  # IdentitiesOnly still uses IdentityFile entries from ~/.ssh/config, so "OK" can also
  # come from another configured key; the ssh-copy-id result above is what matters.
  elif ssh -n -i "${key%.pub}" -p "$port" -o BatchMode=yes -o ConnectTimeout=5 \
           -o IdentitiesOnly=yes "$target" true 2>/dev/null; then
    echo "OK: key login to $target works."
  else
    echo "WARN: key copied, but a key-only login test to $target failed" \
         "(passphrase-protected key without ssh-agent, or the server refuses keys)." >&2
  fi

  ask_yes_no "Copy the same key to another host?" || break
done
