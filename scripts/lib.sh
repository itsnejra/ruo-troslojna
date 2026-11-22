#!/usr/bin/env bash
# Zajedničke pomoćne naredbe (Makefile, testovi i druge skripte). Prvi argument je naredba:
#
#   scripts/lib.sh vault-get IME              jedna vrijednost iz šifrovanog vault.yml (AO-9)
#   scripts/lib.sh tf-dns ARGUMENTI...        terraform u terraform/dns, TSIG tajne iz vaulta
#   scripts/lib.sh tf-retry NAREDBA...        terraform naredba, ponovljena jednom za poznatu grešku
#   scripts/lib.sh nsupdate-key KLJUČ VARIJABLA   privremena datoteka s TSIG ključem za nsupdate
set -euo pipefail
cd "$(dirname "$0")/.."

# Dešifruje se samo u memoriji, ništa se ne upisuje na disk.
vault_get() {
  ansible-vault view --vault-password-file .vault_pass ansible/inventory/group_vars/all/vault.yml \
    | python3 -c 'import sys, yaml; print(yaml.safe_load(sys.stdin)[sys.argv[1]])' "${1:?ime varijable}"
}

# TSIG tajne se predaju Terraformu kroz varijable okruženja TF_VAR_* (obrazac "tf5" iz Makefilea
# predmeta), pa nikad nisu u datoteci.
tf_dns() {
  TF_VAR_tsig_tf_ruo="$(vault_get vault_tsig_tf_ruo)"
  TF_VAR_tsig_tf_ptr="$(vault_get vault_tsig_tf_ptr)"
  export TF_VAR_tsig_tf_ruo TF_VAR_tsig_tf_ptr
  exec terraform -chdir=terraform/dns "$@"
}

# Ponavlja se JEDNOM, i samo za jednu poznatu, prolaznu grešku providera dmacvicar/libvirt 0.8:
# odmah nakon kreiranja cloud-init ISO-a provider ga čita nazad i ponekad dobije "error initializing
# ISO reader: corrupted-image: EOF". ISO je ispravan (provjereno sa isoinfo), resurs je napravljen,
# a sljedeće izvršavanje prolazi. Sve ostale greške se vraćaju s izvornim izlazom i izlaznim kodom.
tf_retry() {
  local log rc
  log="$(mktemp)"; trap 'rm -f "$log"' EXIT
  set +e
  "$@" 2>&1 | tee "$log"; rc=${PIPESTATUS[0]}
  # exit 2 kod "plan -detailed-exitcode" znači "ima promjena", a ne grešku
  if [ "$rc" = 1 ] && grep -q 'error initializing ISO reader: corrupted-image: EOF' "$log"; then
    echo ">> poznata prolazna greška libvirt providera 0.8 (čitanje ISO-a odmah nakon kreiranja); ponavljam jednom"
    sleep 3
    "$@"; rc=$?
  fi
  exit "$rc"
}

# Tajna se ne stavlja u argumente naredbe (vidljivi u listi procesa), nego u datoteku 0600, koju
# pozivalac briše:   kljuc="$(bash scripts/lib.sh nsupdate-key tf-ruo vault_tsig_tf_ruo)"; trap 'rm -f "$kljuc"' EXIT
nsupdate_key() {
  local f
  f="$(mktemp)"; chmod 600 "$f"
  printf 'key "%s" {\n  algorithm hmac-sha256;\n  secret "%s";\n};\n' "${1:?ime ključa}" "$(vault_get "${2:?vault varijabla}")" > "$f"
  echo "$f"
}

naredba="${1:-}"; shift || true
case "$naredba" in
  vault-get)    vault_get "$@" ;;
  tf-dns)       tf_dns "$@" ;;
  tf-retry)     tf_retry "$@" ;;
  nsupdate-key) nsupdate_key "$@" ;;
  *) echo "Upotreba: $0 vault-get IME | tf-dns ARG... | tf-retry NAREDBA... | nsupdate-key KLJUČ VARIJABLA" >&2; exit 1 ;;
esac
