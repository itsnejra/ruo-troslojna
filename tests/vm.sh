#!/usr/bin/env bash
# Provjera VM-ova (AO-3, AO-4):
#   * Terraform plan nakon apply nema promjena (stanje = kod),
#   * svaki VM je na adresi iz adresnog plana i cloud-init je završio,
#   * prijava ključem radi uz provjeru ključa servera (known_hosts iz Terraforma),
#   * prijava lozinkom je odbijena (sshd je ni ne nudi).
set -uo pipefail
cd "$(dirname "$0")/.."

GRESKE=0
tvrdi() { local opis="$1"; shift; if "$@"; then echo "  ok: $opis"; else echo "  NIJE OK: $opis"; GRESKE=$((GRESKE + 1)); fi; }

KEY="${RUO_SSH_KEY:-$HOME/.ssh/ruo_ed25519}"
USR="$(terraform -chdir=terraform/vm output -raw admin_user 2>/dev/null || echo ops)"
# -n: ssh ne čita standardni ulaz (inače pojede ostatak liste hostova u while petlji)
SSH_OPT=(-n -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=ansible/known_hosts)

echo "== AO-3: terraform plan nakon apply"
bash scripts/tf-retry.sh terraform -chdir=terraform/vm plan -input=false -detailed-exitcode >/dev/null 2>&1; rc=$?
tvrdi "terraform/vm: plan bez promjena (exit $rc)" test "$rc" = 0

echo "== AO-4: VM-ovi, cloud-init i SSH"
while read -r ime ip; do
  echo "-- $ime ($ip)"
  out="$(ssh "${SSH_OPT[@]}" -i "$KEY" "$USR@$ip" \
        'hostname; cloud-init status | cut -d" " -f2; ip -4 -br addr show scope global | awk "{print \$3}"' 2>&1)"
  tvrdi "prijava ključem uz provjeru ključa servera" test -n "$out"
  tvrdi "hostname je $ime" test "$(sed -n 1p <<< "$out")" = "$ime"
  tvrdi "cloud-init: done" test "$(sed -n 2p <<< "$out")" = "done"
  tvrdi "adresa je iz adresnog plana" grep -q "^$ip/" <<< "$(sed -n 3p <<< "$out")"
  pw="$(ssh -n -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=ansible/known_hosts \
        -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive "$USR@$ip" true 2>&1)"
  tvrdi "prijava lozinkom odbijena (sshd nudi samo publickey)" grep -q 'Permission denied (publickey)' <<< "$pw"
done < <(terraform -chdir=terraform/vm output -json hosts | python3 -c 'import json,sys; [print(k, v["ip"]) for k, v in sorted(json.load(sys.stdin).items())]')

echo; [ "$GRESKE" = 0 ] && echo "VM-ovi: sve provjere su prošle." || { echo "VM-ovi: neuspjelih provjera: $GRESKE"; exit 1; }
