#!/usr/bin/env bash
# AO-7 i AO-8: autoritativni DNS projekta i zapisi kao kod.
#   * svako ime odgovara adresi iz Terraform outputa (A, CNAME, PTR),
#   * server je autoritativan (aa), nije rekurzivan (REFUSED), zona se ne daje bez ključa (AXFR),
#   * TSIG ključ smije SAMO svoju zonu i SAMO dozvoljene tipove (update izvan toga: REFUSED),
#   * VM-ovi razrješavaju servisna imena preko svog resolvera (ns1),
#   * terraform plan za DNS nema promjena.
set -uo pipefail
cd "$(dirname "$0")/.."

GRESKE=0
tvrdi() { local opis="$1"; shift; if "$@"; then echo "  ok: $opis"; else echo "  NIJE OK: $opis"; GRESKE=$((GRESKE + 1)); fi; }

ZONA="$(terraform -chdir=terraform/vm output -raw zone)"
NS="$(terraform -chdir=terraform/vm output -raw dns_server)"
REV="$(awk -F. '{print $2"."$1".in-addr.arpa"}' <<< "$NS")"   # reverzna zona /16 projekta
D=(dig +short +time=2 +tries=1 @"$NS")
declare -A IP
while read -r ime ip; do IP[$ime]=$ip; done < <(terraform -chdir=terraform/vm output -json hosts | python3 -c 'import json,sys; [print(k, v["ip"]) for k, v in json.load(sys.stdin).items()]')

echo "== AO-7: zapisi (dig @$NS)"
for par in frontend:web1 backend:app1 db:db1; do
  ime="${par%%:*}"; host="${par##*:}"
  tvrdi "$ime.$ZONA -> ${IP[$host]} ($host)" test "$("${D[@]}" "$ime.$ZONA" A)" = "${IP[$host]}"
done
for h in "${!IP[@]}"; do
  tvrdi "$h.$ZONA -> ${IP[$h]}" test "$("${D[@]}" "$h.$ZONA" A)" = "${IP[$h]}"
  tvrdi "PTR ${IP[$h]} -> $h.$ZONA." test "$("${D[@]}" -x "${IP[$h]}")" = "$h.$ZONA."
done
tvrdi "www.$ZONA je CNAME na frontend" test "$("${D[@]}" "www.$ZONA" CNAME)" = "frontend.$ZONA."

echo "== ponašanje servera"
tvrdi "odgovor je autoritativan (zastavica aa)" grep -q 'flags:.* aa' <<< "$(dig @"$NS" "$ZONA" SOA)"
tvrdi "nepostojeće ime: NXDOMAIN" grep -q 'status: NXDOMAIN' <<< "$(dig @"$NS" "nema.$ZONA" A)"
tvrdi "tuđa domena: REFUSED (nije rekurzivni server)" grep -q 'status: REFUSED' <<< "$(dig @"$NS" example.com A)"
tvrdi "AXFR bez ključa: odbijen" grep -q 'Transfer failed' <<< "$(dig @"$NS" "$ZONA" AXFR)"
kljuc_ruo="$(bash scripts/lib.sh nsupdate-key tf-ruo vault_tsig_tf_ruo)"
kljuc_ptr="$(bash scripts/lib.sh nsupdate-key tf-ptr vault_tsig_tf_ptr)"
trap 'rm -f "$kljuc_ruo" "$kljuc_ptr"' EXIT
n_axfr="$(dig -k "$kljuc_ruo" @"$NS" "$ZONA" AXFR | grep -c "IN")"
tvrdi "AXFR s ključem tf-ruo: dozvoljen ($n_axfr zapisa)" test "$n_axfr" -gt 5

echo "== AO-8: prava TSIG ključeva (svaki pokušaj izvan dozvoljenog mora biti REFUSED)"
odbijen() { # ključ zona update-red
  local out; out="$(printf 'server %s\nzone %s\n%s\nsend\n' "$NS" "$2" "$3" | nsupdate -k "$1" 2>&1)"
  grep -q 'REFUSED' <<< "$out"
}
tvrdi "tf-ruo ne smije u reverznu zonu" odbijen "$kljuc_ruo" "$REV" "update add 99.99.$REV. 300 PTR uljez.$ZONA."
tvrdi "tf-ruo ne smije mijenjati NS (delegaciju)" odbijen "$kljuc_ruo" "$ZONA" "update add uljez.$ZONA. 300 NS ns1.$ZONA."
tvrdi "tf-ptr ne smije u zonu projekta" odbijen "$kljuc_ptr" "$ZONA" "update add uljez.$ZONA. 300 TXT test"
tvrdi "tf-ptr ne smije A zapis ni u svojoj zoni" odbijen "$kljuc_ptr" "$REV" "update add 99.99.$REV. 300 A ${IP[ns1]}"
tvrdi "uljez nije upisan" test -z "$("${D[@]}" "uljez.$ZONA" ANY)"

echo "== VM-ovi razrješavaju servisna imena preko ns1 (resolver iz cloud-inita)"
S=(-n -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=ansible/known_hosts -i "${RUO_SSH_KEY:-$HOME/.ssh/ruo_ed25519}")
tvrdi "web1: backend -> ${IP[app1]}" test "$(ssh "${S[@]}" "ops@${IP[web1]}" "getent ahostsv4 backend.$ZONA | awk 'NR==1{print \$1}'")" = "${IP[app1]}"
tvrdi "app1: db -> ${IP[db1]}" test "$(ssh "${S[@]}" "ops@${IP[app1]}" "getent ahostsv4 db.$ZONA | awk 'NR==1{print \$1}'")" = "${IP[db1]}"

echo "== AO-8: terraform plan za DNS"
bash scripts/lib.sh tf-dns plan -input=false -detailed-exitcode >/dev/null 2>&1; rc=$?
tvrdi "terraform/dns: plan bez promjena (exit $rc)" test "$rc" = 0

echo; [ "$GRESKE" = 0 ] && echo "DNS: sve provjere su prošle." || { echo "DNS: neuspjelih provjera: $GRESKE"; exit 1; }
