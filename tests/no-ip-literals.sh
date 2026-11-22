#!/usr/bin/env bash
# AO-7: komponente se adresiraju isključivo DNS imenima. Ovaj test radi isto što i asistent na
# odbrani, "pretraga koda za IP adrese", samo automatski i pri svakom make test.
#
# Jedini dozvoljeni IP literal je supernet projekta u terraform/vm/variables.tf (DO-3): iz njega se
# funkcijama cidrsubnet/cidrhost izvode sve adrese, a ostatak sistema ih dobija iz outputa.
# 0.0.0.0 nije adresa komponente nego "sluša na svim sučeljima", pa je izuzet.
set -uo pipefail
cd "$(dirname "$0")/.."

DOZVOLJENO='^terraform/vm/variables\.tf:'
# --cached --others --exclude-standard: praćene i nove datoteke, ali ne generisane/ignorisane
# (generisani inventory s adresama je izlaz Terraforma, ne kod).
pogoci="$(git ls-files -z --cached --others --exclude-standard -- app ansible terraform packer tests scripts Makefile \
  | xargs -0 grep -nIE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' 2>/dev/null \
  | grep -vE "$DOZVOLJENO" | grep -v '0\.0\.0\.0' | grep -v 'no-ip-literals.sh')"

echo "== AO-7: IP literali u kodu (dozvoljen samo project_cidr u terraform/vm/variables.tf)"
if [ -z "$pogoci" ]; then
  echo "  ok: nema IP literala izvan adresnog plana"
  echo "  adresni plan: $(grep -nE '\b([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+' terraform/vm/variables.tf | tr -s ' ')"
else
  echo "  NIJE OK: pronađeni IP literali:"; sed 's/^/    /' <<< "$pogoci"; exit 1
fi
