#!/usr/bin/env bash
# make test: svi testovi redom, sa sažetkom na kraju (izlaz ide u README kao dokaz).
# Testovi ne zavise jedan od drugog, pa se izvršavaju svi i kad neki padne; exit kod je 1 ako je
# ijedan pao. Testovi izolacije i aplikacije traže sudo (promet iz namespace-a klijenta).
set -uo pipefail
cd "$(dirname "$0")/.."

ZONA="$(terraform -chdir=terraform/vm output -raw zone)"
sudo -v || { echo "make test treba sudo (namespace klijenta)."; exit 1; }

declare -a REZ
pokreni() { # opis naredba...
  local opis="$1"; shift
  printf '\n\033[1;36m######## %s\033[0m\n' "$opis"
  if "$@"; then REZ+=("ok        $opis"); else REZ+=("PALO      $opis"); fi
}

pokreni "AO-3/AO-4  VM-ovi: plan bez promjena, cloud-init, SSH, sat"   bash tests/vm.sh
pokreni "AO-6       izolacija: matrica povezivosti"                     bash tests/isolation.sh
pokreni "AO-7/AO-8  DNS: zapisi, server, prava TSIG ključeva, plan"     bash tests/dns.sh
pokreni "AO-7       nema IP literala u kodu"                            bash tests/no-ip-literals.sh
pokreni "AO-1       aplikacija iz interneta (www.$ZONA)"               sudo ip netns exec ruo-klijent bash tests/app.sh "http://www.$ZONA"
pokreni "AO-10      perzistencija podataka baze"                        bash tests/persistence.sh
pokreni "AO-9       tajne nisu u Gitu (ni u historiji)"                 bash tests/secrets.sh

printf '\n\033[1m======== SAŽETAK ========\033[0m\n'
printf '  %s\n' "${REZ[@]}"
if printf '%s\n' "${REZ[@]}" | grep -q '^PALO'; then echo "Neki testovi su pali."; exit 1; fi
echo "Svi testovi su prošli."
