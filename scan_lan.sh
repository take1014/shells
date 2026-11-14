#!/usr/bin/env bash
# List hosts reachable on the local network and which remote-access ports they accept.
# Only directly attached subnets are scanned (never anything behind the router).
# Portable: needs bash 4.3+, iproute2 (ip), ping, getent, awk, xargs and coreutils. No root.
#
# Usage:
#   bash scan_lan.sh                  # scan the subnet of the default-route interface
#   bash scan_lan.sh 192.168.3.0/24   # scan the given attached subnet (prefix /22 to /30)
set -euo pipefail

# Ports checked on each host: "port:service".
PORTS=(22:ssh 445:smb 3389:rdp 5900:vnc)
PING_PARALLEL=64
HOST_PARALLEL=16

die() { echo "ERROR: $*" >&2; exit 1; }

for cmd in ip ping getent awk xargs timeout sort mktemp; do
  command -v "$cmd" >/dev/null || die "required command not found: $cmd"
done

ip_to_int() {  # <a.b.c.d> (octets parsed as decimal, never octal)
  local a b c d
  IFS=. read -r a b c d <<< "$1"
  echo $(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
}

int_to_ip() {  # <int>
  echo "$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"
}

net_of() {  # <a.b.c.d/prefix> -> network address as int
  local p="${1#*/}"
  echo $(( $(ip_to_int "${1%/*}") & ((0xFFFFFFFF << (32 - 10#$p)) & 0xFFFFFFFF) ))
}

# --- determine the subnet and its interface -------------------------------

if [[ $# -ge 1 ]]; then
  cidr="$1"
  [[ "$cidr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] \
    || die "invalid subnet: $cidr (expected e.g. 192.168.1.0/24)"
  for o in "${BASH_REMATCH[@]:1:4}"; do
    (( 10#$o <= 255 )) || die "invalid octet '$o' in $cidr"
  done
else
  def_iface="$(ip -4 route show default | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
  [[ -n "$def_iface" ]] || die "no default route; pass a subnet like 192.168.1.0/24."
  cidr="$(ip -4 -o addr show dev "$def_iface" scope global | awk '{ print $4; exit }')"
  [[ -n "$cidr" ]] || die "no IPv4 address on $def_iface."
fi
prefix=$(( 10#${cidr#*/} ))
(( prefix >= 22 && prefix <= 30 )) || die "prefix /$prefix not supported (use /22 to /30)."
net=$(net_of "$cidr")
bcast=$(( net | (~((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF) & 0xFFFFFFFF) ))

# Pick the local interface whose own subnet contains the target network.
iface=""
while read -r dev addr; do
  p=$(( 10#${addr#*/} ))
  (( p <= prefix )) || continue
  if (( $(net_of "$addr") == (net & ((0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF)) )); then
    iface="$dev"; break
  fi
done < <(ip -4 -o addr show scope global | awk '{ print $2, $4 }')
[[ -n "$iface" ]] || die "$(int_to_ip "$net")/$prefix is not a directly attached network."

self_ips=" $(ip -4 -o addr show | awk '{ split($4, a, "/"); printf "%s ", a[1] }')"
gateway="$(ip -4 route show default dev "$iface" 2>/dev/null | awk '{ print $3; exit }')" || true

# Unprivileged ping may be unavailable (e.g. busybox without ping_group_range).
ping -c 1 -W 1 127.0.0.1 >/dev/null 2>&1 \
  || die "ping does not work for this user (try iputils ping, or run with sudo)."

echo "Scanning $(int_to_ip "$net")/$prefix on $iface ..." >&2

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

# --- 1. ping sweep (also triggers ARP for every address) ------------------

for (( i = net + 1; i < bcast; i++ )); do int_to_ip "$i"; done \
  | xargs -P "$PING_PARALLEL" -I{} sh -c 'ping -c 1 -W 1 -q "$1" >/dev/null 2>&1 && echo "$1"' _ {} \
  > "$work/alive" || true

# --- 2. hosts that answer ARP but drop ping (e.g. Windows firewall) -------
# Entries left over from earlier contact sit in DELAY/PROBE for a few seconds even
# when the host is gone, so wait for the kernel to confirm them and trust only REACHABLE.

if ip -4 neigh show dev "$iface" | grep -qE ' (DELAY|PROBE)$'; then
  sysd="/proc/sys/net/ipv4/neigh/$iface"
  delay=$(cat "$sysd/delay_first_probe_time" 2>/dev/null || echo 5)
  probes=$(cat "$sysd/ucast_solicit" 2>/dev/null || echo 3)
  retrans_ms=$(cat "$sysd/retrans_time_ms" 2>/dev/null || echo 1000)
  wait_s=$(( delay + (probes * retrans_ms + 999) / 1000 ))
  echo "Waiting ${wait_s}s to confirm hosts that do not answer ping ..." >&2
  sleep "$wait_s"
fi
ip -4 neigh show dev "$iface" nud reachable | awk '{ print $1 }' >> "$work/alive"

mapfile -t hosts < <(sort -u -t. -k1,1n -k2,2n -k3,3n -k4,4n "$work/alive")

# --- 3. details per host (hosts in parallel, ports in parallel) -----------

port_open() {  # <ip> <port>
  timeout 1 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null
}

host_line() {  # <ip>
  local host="$1" mac name note="" p open=() i
  mac="$(ip -4 neigh show "$host" | awk '{ for (i = 1; i < NF; i++) if ($i == "lladdr") { print $(i + 1); exit } }')" || true
  name="$(timeout 2 getent hosts "$host" | awk '{ print $2; exit }')" || true
  [[ "$self_ips" == *" $host "* ]] && note+=" (this PC)"
  [[ "$host" == "$gateway" ]] && note+=" (router)"

  local -a pids=()
  for i in "${!PORTS[@]}"; do
    port_open "$host" "${PORTS[$i]%%:*}" & pids[$i]=$!
  done
  for i in "${!PORTS[@]}"; do
    p="${PORTS[$i]}"
    if wait "${pids[$i]}"; then open+=("${p#*:}/${p%%:*}"); fi
  done
  printf '%-15s  %-17s  %-30s  %s\n' "$host" "${mac:--}" "${name:--}$note" "${open[*]:--}"
}

idx=0
for host in ${hosts[@]+"${hosts[@]}"}; do
  h=$(ip_to_int "$host")
  (( h > net && h < bcast )) || continue   # keep only addresses inside the subnet
  while (( $(jobs -rp | wc -l) >= HOST_PARALLEL )); do wait -n || true; done
  host_line "$host" > "$work/line.$(printf '%05d' "$idx")" &
  idx=$(( idx + 1 ))
done
wait || true

printf '%-15s  %-17s  %-30s  %s\n' "IP" "MAC" "HOSTNAME" "OPEN PORTS"
if (( idx > 0 )); then
  cat "$work"/line.*
fi
echo "$idx host(s) found." >&2
