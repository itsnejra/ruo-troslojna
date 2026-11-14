#!/usr/bin/env bash
# Pokreće terraform naredbu i ponavlja je JEDNOM, ali samo za jednu poznatu, prolaznu grešku
# providera dmacvicar/libvirt 0.8: odmah nakon kreiranja cloud-init ISO-a provider ga čita nazad
# i ponekad dobije "error initializing ISO reader: corrupted-image: EOF". ISO je ispravan
# (provjereno sa isoinfo), resurs je napravljen, a sljedeće izvršavanje prolazi i konvergira.
# Sve ostale greške se ne ponavljaju: skripta vraća izvorni izlaz i izlazni kod.
#
#   scripts/tf-retry.sh terraform -chdir=terraform/vm apply -auto-approve
set -uo pipefail

log="$(mktemp)"; trap 'rm -f "$log"' EXIT
"$@" 2>&1 | tee "$log"; rc=${PIPESTATUS[0]}

# exit 2 kod "plan -detailed-exitcode" znači "ima promjena", a ne grešku
if [ "$rc" = 1 ] && grep -q 'error initializing ISO reader: corrupted-image: EOF' "$log"; then
  echo ">> poznata prolazna greška libvirt providera 0.8 (čitanje ISO-a odmah nakon kreiranja); ponavljam jednom"
  sleep 3
  "$@"; rc=$?
fi
exit "$rc"
