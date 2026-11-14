#!/usr/bin/env bash
# Provisioner zlatne slike (DO-4). Izvršava se jednom, pri izgradnji, kao root.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "== čekam da cloud-init build mašine završi"
cloud-init status --wait >/dev/null || true

echo "== paketi"
apt-get update
apt-get -y upgrade
# Docker iz Ubuntu arhive (isti paketi kao na kontrolnom čvoru): potpisani su ključem distribucije,
# pa nije potreban dodatni apt repozitorij.
apt-get install -y --no-install-recommends \
  docker.io docker-compose-v2 python3-docker \
  nftables \
  bind9 bind9-utils bind9-dnsutils \
  qemu-guest-agent \
  curl netcat-openbsd ca-certificates

echo "== servisi se ne pokreću sami: ulogu VM-a određuje Ansible"
# Na web/app/db Ansible uključuje Docker (nakon što postavi daemon.json), na ns1 uključuje BIND.
systemctl disable docker.service docker.socket named.service
systemctl enable nftables.service

echo "== verzija slike"
echo "ruo-base ${RUO_IMAGE_TAG:-nepoznato} $(date -u +%Y-%m-%dT%H:%MZ)" > /etc/ruo-image-version

echo "== čišćenje: slika ne smije nositi tragove izgradnje"
apt-get -y autoremove --purge
apt-get clean
rm -rf /var/lib/apt/lists/*
# build lozinka se zaključava; korisnik ubuntu ostaje bez lozinke i bez ključa
passwd -l ubuntu
# cloud-init se ponovo izvršava pri prvom pokretanju svake mašine iz slike (s2/p4)
cloud-init clean --logs --seed
# jedinstven machine-id po instanci (generiše ga systemd pri prvom pokretanju)
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
# ključevi servera: svaki VM dobija svoj ključ iz Terraforma (DO-6)
rm -f /etc/ssh/ssh_host_*
sync
