#!/usr/bin/env bash
# AO-9: tajne nikad nisu u Gitu u čistom obliku. Na odbrani se provjerava "pregledom historije
# repozitorija"; ovaj test radi isto, automatski:
#   * nijedna datoteka s tajnom ni stanje nije praćena u Gitu (ni sada ni ikad u historiji),
#   * stvarne vrijednosti tajni (iz vaulta) se ne pojavljuju ni u jednom commitu, ni u jednoj grani,
#   * vault.yml na disku je šifrovan.
set -uo pipefail
cd "$(dirname "$0")/.."

GRESKE=0
tvrdi() { local opis="$1"; shift; if "$@"; then echo "  ok: $opis"; else echo "  NIJE OK: $opis"; GRESKE=$((GRESKE + 1)); fi; }
VAULT=ansible/inventory/group_vars/all/vault.yml

echo "== AO-9: tajne i Git"
ZABRANJENO='(^|/)(\.vault_pass|vault\.yml|[^/]*\.tfstate[^/]*|\.env|[^/]*\.key|[^/]*\.pem|id_[a-z0-9]+)$'
sada="$(git ls-files | grep -E "$ZABRANJENO" | grep -v '\.example$')"
tvrdi "nijedna datoteka s tajnom ili stanjem nije praćena sada" test -z "$sada"
ikad="$(git log --all --pretty=format: --name-only | sort -u | grep -E "$ZABRANJENO" | grep -v '\.example$')"
tvrdi "nijedna takva datoteka nije ni u historiji ($(git rev-list --all --count) commitova)" test -z "$ikad"

tvrdi "vault.yml je šifrovan (AES256)" grep -q '^\$ANSIBLE_VAULT;1.1;AES256' "$VAULT"
tvrdi "vault.yml je ignorisan u Gitu" git check-ignore -q "$VAULT"
tvrdi ".vault_pass je ignorisan u Gitu" git check-ignore -q .vault_pass

# Stvarne vrijednosti se traže u svim verzijama svih datoteka u svim granama.
# git grep -F: vrijednost se ne ispisuje, nego samo da li postoji.
for ime in vault_db_password vault_tsig_tf_ruo vault_tsig_tf_ptr; do
  v="$(bash scripts/vault-get.sh "$ime")"
  # shellcheck disable=SC2046
  if git grep -qF -- "$v" $(git rev-list --all) 2>/dev/null; then nadjeno=da; else nadjeno=ne; fi
  tvrdi "vrijednost $ime se ne pojavljuje ni u jednom commitu" test "$nadjeno" = ne
done
privatni="$(git log --all -p | grep -c 'PRIVATE KEY-----' || true)"
tvrdi "nijedan privatni ključ (PEM/OpenSSH) u historiji" test "$privatni" = 0

echo; [ "$GRESKE" = 0 ] && echo "Tajne: nijedna tajna nije u Gitu." || { echo "Tajne: neuspjelih provjera: $GRESKE"; exit 1; }
