#!/usr/bin/env bash
# Demonstracija drifta u DNS-u (AO-8; obrazac s5/p2/drift.sh). Zapise koje posjeduje Terraform
# mijenjamo "ručno", mimo koda, alatom nsupdate (RFC 2136, isti ključ). Zatim:
#   1. terraform plan otkriva razliku između koda i stvarnosti,
#   2. terraform apply vraća stvarnost na stanje iz koda.
set -uo pipefail
cd "$(dirname "$0")/.."

ZONA="$(terraform -chdir=terraform/vm output -raw zone)"
NS="$(terraform -chdir=terraform/vm output -raw dns_server)"
DB_IP="$(dig +short @"$NS" "db.$ZONA" A | head -1)"
POGRESNA="${DB_IP%.*}.99"          # ista podmreža, pogrešan host
kljuc="$(bash scripts/lib.sh nsupdate-key tf-ruo vault_tsig_tf_ruo)"; trap 'rm -f "$kljuc"' EXIT
korak() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

korak "0. stanje prije: backend i db"
echo "backend.$ZONA -> $(dig +short @"$NS" "backend.$ZONA" A)"
echo "db.$ZONA      -> $DB_IP"

korak "1. DRIFT: nsupdate briše backend i mijenja adresu za db (mimo Terraforma)"
echo "\$ nsupdate -k tf-ruo.key"
nsupdate -k "$kljuc" <<EOF
server $NS
zone $ZONA
update delete backend.$ZONA. A
update delete db.$ZONA. A
update add db.$ZONA. 300 A $POGRESNA
send
EOF
sleep 1
echo "backend.$ZONA -> '$(dig +short @"$NS" "backend.$ZONA" A)'   (nema ga)"
echo "db.$ZONA      -> $(dig +short @"$NS" "db.$ZONA" A)   (pogrešna adresa)"

korak "2. terraform plan: Terraform vidi razliku (exit 2 = ima promjena)"
bash scripts/lib.sh tf-dns plan -input=false -no-color -detailed-exitcode 2>&1 \
  | grep -E '^  # |^      [~+-] |^\s+[+-] "|^Plan:'
echo "exit: ${PIPESTATUS[0]}"

korak "3. terraform apply: stvarnost se vraća na stanje iz koda"
bash scripts/lib.sh tf-dns apply -auto-approve -input=false -no-color 2>&1 | grep -E 'Apply complete'
echo "backend.$ZONA -> $(dig +short @"$NS" "backend.$ZONA" A)"
echo "db.$ZONA      -> $(dig +short @"$NS" "db.$ZONA" A)"

korak "4. terraform plan ponovo: bez promjena"
bash scripts/lib.sh tf-dns plan -input=false -no-color -detailed-exitcode 2>&1 | grep -E 'No changes'
