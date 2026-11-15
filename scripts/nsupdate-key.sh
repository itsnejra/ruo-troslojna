#!/usr/bin/env bash
# Privremena datoteka s TSIG ključem za nsupdate (0600, briše se pri izlazu skripte koja je koristi).
# Tajna se ne stavlja u argumente naredbe (vidljivi u listi procesa).
#   kljuc="$(scripts/nsupdate-key.sh tf-ruo vault_tsig_tf_ruo)"; trap 'rm -f "$kljuc"' EXIT
set -euo pipefail
cd "$(dirname "$0")/.."
f="$(mktemp)"; chmod 600 "$f"
printf 'key "%s" {\n  algorithm hmac-sha256;\n  secret "%s";\n};\n' "${1:?ime ključa}" "$(bash scripts/vault-get.sh "${2:?vault varijabla}")" > "$f"
echo "$f"
