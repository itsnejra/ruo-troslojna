#!/usr/bin/env bash
# AO-6: matrica povezivosti (proširenje s4/p3/test.sh na prave VM-ove).
# Za svaki par izvor -> odredište:port pokušava TCP vezu i poredi ishod s politikom.
# Ako na odredištu servis još ne radi, test privremeno pokreće slušaoca (nc) na tom portu,
# pa se provjerava MREŽA, a ne to da li je aplikacija podignuta.
# Traži sudo na hostu (promet iz namespace-a klijenta, "internet").
set -uo pipefail
cd "$(dirname "$0")/.."

KEY="${RUO_SSH_KEY:-$HOME/.ssh/ruo_ed25519}"
S=(-n -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=ansible/known_hosts -i "$KEY")
NS="$(terraform -chdir=terraform/vm output -json client | python3 -c 'import json,sys; print(json.load(sys.stdin)["netns"])')"
declare -A IP
while read -r ime ip; do IP[$ime]=$ip; done < <(terraform -chdir=terraform/vm output -json hosts | python3 -c 'import json,sys; [print(k, v["ip"]) for k, v in json.load(sys.stdin).items()]')
KLIJENT_IP="$(terraform -chdir=terraform/vm output -json client | python3 -c 'import json,sys; print(json.load(sys.stdin)["ip"])')"

sudo -v || { echo "Test treba sudo (namespace klijenta)."; exit 1; }
sudo ip netns list | grep -qw "$NS" || { echo "Namespace $NS ne postoji: prvo make config"; exit 1; }

# --- privremeni slušaoci (samo gdje servis ne radi) ---
POKRENUTI=()
slusaj() { # vm port
  if ssh "${S[@]}" "ops@${IP[$1]}" "ss -Hltn 'sport = :$2' | grep -q ." ; then return; fi
  ssh "${S[@]}" "ops@${IP[$1]}" "sudo systemd-run --quiet --unit=ruo-test-$2 --collect timeout 120 nc -lk $2"
  POKRENUTI+=("$1:$2")
}
pocisti() { for x in "${POKRENUTI[@]}"; do ssh "${S[@]}" "ops@${IP[${x%%:*}]}" "sudo systemctl stop ruo-test-${x##*:} 2>/dev/null" || true; done
            sudo pkill -f "ruo-test-klijent" 2>/dev/null || true; }
trap pocisti EXIT

slusaj web1 80; slusaj app1 8000; slusaj db1 5432
# "internet" sluša na 9000: provjera da segmenti nemaju izlaz
sudo ip netns exec "$NS" bash -c 'exec -a ruo-test-klijent timeout 120 nc -lk 9000' >/dev/null 2>&1 &
sleep 1

GRESKE=0
proba() { # izvor odredište port očekivano opis
  local izv="$1" cilj="$2" port="$3" ocek="$4" opis="$5" ip rez
  if [ "$cilj" = klijent ]; then ip="$KLIJENT_IP"; else ip="${IP[$cilj]}"; fi
  case "$izv" in
    klijent) sudo ip netns exec "$NS" timeout 3 bash -c "exec 3<>/dev/tcp/$ip/$port" 2>/dev/null ;;
    host)    timeout 3 bash -c "exec 3<>/dev/tcp/$ip/$port" 2>/dev/null ;;
    *)       ssh "${S[@]}" "ops@${IP[$izv]}" "nc -z -w2 $ip $port" 2>/dev/null ;;
  esac && rez=dozvoljeno || rez=blokirano
  if [ "$rez" = "$ocek" ]; then oz="ok"; else oz="RAZLIKA"; GRESKE=$((GRESKE + 1)); fi
  printf '  %-8s -> %-8s :%-5s %-11s (očekivano: %-10s) %-7s %s\n' "$izv" "$cilj" "$port" "$rez" "$ocek" "$oz" "$opis"
}

echo "== AO-6: matrica povezivosti (izvor -> odredište:port)"
proba klijent web1 80   dozvoljeno "internet -> frontend: jedini ulaz izvana"
proba klijent app1 8000 blokirano  "internet -> backend"
proba klijent db1  5432 blokirano  "internet -> baza"
proba web1    app1 8000 dozvoljeno "frontend -> backend"
proba web1    db1  5432 blokirano  "frontend -> baza: PRESKAKANJE SLOJA (ključni test)"
proba app1    db1  5432 dozvoljeno "backend -> baza"
proba app1    web1 80   blokirano  "obrnuti smjer: backend -> frontend"
proba db1     app1 8000 blokirano  "obrnuti smjer: baza -> backend"
proba web1    app1 22   blokirano  "SSH između VM-ova"
proba db1     klijent 9000 blokirano "baza -> internet (nema izlaza)"
proba web1    klijent 9000 blokirano "frontend -> internet (nema izlaza)"
proba host    db1  22   dozvoljeno "admin (host) -> SSH"
proba host    db1  5432 blokirano  "admin (host) -> baza: i host vidi samo SSH"

# Ako kontejner frontenda radi, isti ključni test i iz SAMOG kontejnera (AO-6 doslovno)
if ssh "${S[@]}" "ops@${IP[web1]}" "sudo docker ps --format '{{.Names}}' | grep -qx ruo-frontend-1"; then
  ssh "${S[@]}" "ops@${IP[web1]}" "sudo docker exec ruo-frontend-1 nc -z -w2 ${IP[db1]} 5432" 2>/dev/null && rez=dozvoljeno || rez=blokirano
  [ "$rez" = blokirano ] && oz=ok || { oz=RAZLIKA; GRESKE=$((GRESKE + 1)); }
  printf '  %-8s -> %-8s :%-5s %-11s (očekivano: %-10s) %-7s %s\n' "frontend" "db1" 5432 "$rez" blokirano "$oz" "iz kontejnera frontenda"
fi

echo "== DNS iz namespace-a klijenta (udp/53 prema ns1)"
odg="$(sudo ip netns exec "$NS" dig +short +time=2 +tries=1 "ns1.$(terraform -chdir=terraform/vm output -raw zone)" A)"
[ "$odg" = "${IP[ns1]}" ] && echo "  ok: klijent razrješava imena preko ns1" || { echo "  NIJE OK: dig iz klijenta: '$odg'"; GRESKE=$((GRESKE + 1)); }

echo; [ "$GRESKE" = 0 ] && echo "Izolacija: ishod je jednak politici u svim slučajevima." || { echo "Izolacija: razlika od politike: $GRESKE"; exit 1; }
