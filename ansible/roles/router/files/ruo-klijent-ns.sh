#!/usr/bin/env bash
# Namespace koji glumi internet (kao ruo5-van u s5): klijent je spojen veth parom na host, a host ga
# usmjerava prema segmentima. Promet klijenta zato prolazi kroz forward lanac rutera, kao pravi
# promet izvana, pa se politika "izvana je dostupan samo frontend" (AO-6) može stvarno testirati.
#
#   ruo-klijent-ns up   NS VETH HOST_CIDR KLIJENT_CIDR GATEWAY DNS_IP ZONA
#   ruo-klijent-ns down NS VETH
#
# Idempotentno: svaki korak prvo provjerava stanje. Ispisuje "PROMJENA" samo ako je nešto mijenjao,
# po čemu Ansible zna da li da javi "changed".
set -euo pipefail
export PATH="$PATH:/usr/sbin:/sbin"

gore() {
  local ns="$1" veth="$2" host_cidr="$3" kl_cidr="$4" gw="$5" dns="$6" zona="$7" p=0
  ip netns list | grep -qw "$ns" || { ip netns add "$ns"; p=1; }
  ip link show "$veth" >/dev/null 2>&1 || { ip link add "$veth" type veth peer name eth0 netns "$ns"; p=1; }
  ip -br addr show dev "$veth" | grep -qw "$host_cidr" || { ip addr replace "$host_cidr" dev "$veth"; p=1; }
  ip link show "$veth" | grep -q 'state UP\|,UP' || { ip link set "$veth" up; p=1; }
  ip -n "$ns" -br addr show dev eth0 | grep -qw "$kl_cidr" || { ip -n "$ns" addr replace "$kl_cidr" dev eth0; p=1; }
  ip -n "$ns" link show eth0 | grep -q ',UP' || { ip -n "$ns" link set lo up; ip -n "$ns" link set eth0 up; p=1; }
  ip -n "$ns" route show default | grep -q "via $gw" || { ip -n "$ns" route replace default via "$gw"; p=1; }
  # ip netns exec montira /etc/netns/<ns>/resolv.conf preko /etc/resolv.conf: klijent pita naš DNS
  local rc="/etc/netns/$ns/resolv.conf" want
  want="$(printf 'nameserver %s\nsearch %s\n' "$dns" "$zona")"
  [ "$(cat "$rc" 2>/dev/null)" = "$want" ] || { mkdir -p "/etc/netns/$ns"; printf '%s\n' "$want" > "$rc"; p=1; }
  [ "$p" = 1 ] && echo "PROMJENA" || echo "bez promjene"
}

dolje() {
  local ns="$1" veth="$2" p=0
  ip netns list | grep -qw "$ns" && { ip netns pids "$ns" | xargs -r kill 2>/dev/null || true; ip netns del "$ns"; p=1; }
  ip link show "$veth" >/dev/null 2>&1 && { ip link del "$veth"; p=1; }
  [ -d "/etc/netns/$ns" ] && { rm -rf "/etc/netns/$ns"; p=1; }
  [ "$p" = 1 ] && echo "PROMJENA" || echo "bez promjene"
}

case "${1:-}" in
  up) shift; gore "$@" ;;
  down) shift; dolje "$@" ;;
  *) echo "Upotreba: $0 up NS VETH HOST_CIDR KLIJENT_CIDR GATEWAY DNS_IP ZONA | down NS VETH"; exit 1 ;;
esac
