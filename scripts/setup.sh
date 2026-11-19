#!/usr/bin/env bash
# Priprema računara (hosta) za projekat: alati, grupe, libvirt i kolekcije Ansible-a (make setup).
# Obrazac je 00-setup.sh iz repozitorija predmeta, sveden na ono što ovaj projekat koristi.
#
# Idempotentno: instalira se samo ono što nedostaje, pa drugo pokretanje ne mijenja ništa.
# Podržano: Ubuntu 24.04+ (i u WSL2). Pokreće se kao običan korisnik; sudo se traži po potrebi.
set -euo pipefail

c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_step=$'\033[1;36m'; c_off=$'\033[0m'
step() { printf '\n%s== %s%s\n' "$c_step" "$*" "$c_off"; }
ok()   { printf '  %sok%s    %s\n' "$c_ok" "$c_off" "$*"; }
warn() { printf '  %s!!%s    %s\n' "$c_warn" "$c_off" "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

[ "$(id -u)" -ne 0 ] || { echo "Ne pokretati kao root; skripta sama koristi sudo."; exit 1; }
have apt-get || { echo "Skripta podržava samo Ubuntu/Debian (apt)."; exit 1; }
sudo -v

IN_WSL=0; grep -qi microsoft /proc/version 2>/dev/null && IN_WSL=1
HAS_SYSTEMD=0; [ "$(ps -p 1 -o comm= 2>/dev/null || true)" = "systemd" ] && HAS_SYSTEMD=1
NEED_RELOGIN=0

step "1/6 Okruženje"
ok "$(. /etc/os-release && echo "$PRETTY_NAME")"
if [ "$IN_WSL" = 1 ]; then
  ok "WSL2"
  if [ "$HAS_SYSTEMD" = 0 ]; then
    grep -qs '^\s*systemd\s*=\s*true' /etc/wsl.conf || printf '[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf >/dev/null
    warn "systemd nije aktivan (potreban za libvirt i Docker). Uključen je u /etc/wsl.conf:"
    warn "u PowerShellu pokrenuti 'wsl --shutdown', otvoriti Ubuntu i ponovo 'make setup'."
    exit 1
  fi
fi
[ -e /dev/kvm ] && ok "/dev/kvm postoji" || warn "nema /dev/kvm: uključiti virtualizaciju (WSL2: ugniježđena virtualizacija)"

step "2/6 Paketi iz Ubuntua (samo oni koji nedostaju)"
# naredba:paket; isti spisak alata provjerava make check
potrebno="git:git make:make curl:curl openssl:openssl python3:python3 gpg:gnupg
  ansible-playbook:ansible ansible-vault:ansible
  docker:docker.io virsh:libvirt-clients libvirtd:libvirt-daemon-system
  qemu-system-x86_64:qemu-system-x86 qemu-img:qemu-utils
  dig:bind9-dnsutils nsupdate:bind9-dnsutils nft:nftables socat:socat"
paketi=()
for par in $potrebno; do
  naredba="${par%%:*}"; paket="${par##*:}"
  have "$naredba" || [ -x "/usr/sbin/$naredba" ] || paketi+=("$paket")
done
# Compose i buildx su dodaci Docker CLI-ja, pa se provjeravaju kroz docker
if have docker; then
  docker compose version >/dev/null 2>&1 || paketi+=(docker-compose-v2)
  docker buildx version >/dev/null 2>&1 || paketi+=(docker-buildx)
else
  paketi+=(docker-compose-v2 docker-buildx)
fi
if [ ${#paketi[@]} -gt 0 ]; then
  mapfile -t paketi < <(printf '%s\n' "${paketi[@]}" | sort -u)
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${paketi[@]}"
  ok "instalirano: ${paketi[*]}"
else
  ok "svi paketi već postoje"
fi
case "$(command -v docker)" in /mnt/*) warn "docker je Docker Desktop (Windows); preporuka je Docker Engine u WSL-u (docker.io)";; esac

step "3/6 Terraform i Packer (HashiCorp repozitorij)"
if have terraform && have packer; then
  ok "$(terraform version | sed -n 1p), $(packer version | sed -n 1p)"
else
  KEYRING=/usr/share/keyrings/hashicorp-archive-keyring.gpg
  [ -f "$KEYRING" ] || curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor --yes -o "$KEYRING"
  echo "deb [signed-by=$KEYRING] https://apt.releases.hashicorp.com $(. /etc/os-release && echo "$VERSION_CODENAME") main" \
    | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq terraform packer
  ok "terraform i packer instalirani"
fi

step "4/6 Grupe korisnika (libvirt, kvm, docker)"
for g in libvirt kvm docker; do
  if [[ " $(id -nG "$USER") " == *" $g "* ]]; then ok "$USER je u grupi $g"
  else sudo usermod -aG "$g" "$USER"; NEED_RELOGIN=1; warn "$USER dodan u grupu $g"; fi
done

step "5/6 Servisi i libvirt pool"
for s in libvirtd docker; do
  systemctl is-enabled --quiet "$s" 2>/dev/null && systemctl is-active --quiet "$s" && ok "$s radi" \
    || { sudo systemctl enable --now "$s"; ok "$s uključen"; }
done
V="sudo virsh -c qemu:///system"
if $V pool-info default >/dev/null 2>&1; then
  ok "libvirt pool default postoji"
else
  $V pool-define-as default dir --target /var/lib/libvirt/images >/dev/null
  $V pool-autostart default >/dev/null
  ok "napravljen libvirt pool default"
fi
# izlaz u varijablu: "virsh | grep -q" uz pipefail pada kad grep završi prije virsha (SIGPIPE)
stanje="$($V pool-info default 2>/dev/null || true)"
case "$stanje" in *running*) ;; *) $V pool-start default >/dev/null ;; esac

step "6/6 Kolekcije Ansible-a"
cd "$(dirname "$0")/.."
nedostaje=0
for c in ansible.posix community.docker community.general; do
  lista="$(ansible-galaxy collection list "$c" 2>/dev/null || true)"
  grep -q "^$c " <<< "$lista" || nedostaje=1
done
if [ "$nedostaje" = 1 ]; then
  ansible-galaxy collection install -r ansible/requirements.yml
  ok "kolekcije instalirane"
else
  ok "ansible.posix, community.docker, community.general postoje"
fi

printf '\n%sGotovo.%s Sljedeći korak: make check, pa make all\n' "$c_ok" "$c_off"
if [ "$NEED_RELOGIN" = 1 ]; then
  warn "Korisnik je dodan u nove grupe. Treba se ponovo prijaviti (WSL: 'wsl --shutdown' u PowerShellu)."
fi
