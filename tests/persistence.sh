#!/usr/bin/env bash
# AO-10: podaci baze preživljavaju ponovno kreiranje kontejnera baze.
# Tačno ono što se radi na odbrani: unos podatka -> ponovno kreiranje -> provjera.
# Upis i čitanje idu kroz CIJELU aplikaciju (frontend na web1 -> backend -> baza), ne direktno u bazu.
set -uo pipefail
cd "$(dirname "$0")/.."

KEY="${RUO_SSH_KEY:-$HOME/.ssh/ruo_ed25519}"
S=(-n -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=ansible/known_hosts -i "$KEY")
declare -A IP
while read -r ime ip; do IP[$ime]=$ip; done < <(terraform -chdir=terraform/vm output -json hosts | python3 -c 'import json,sys; [print(k, v["ip"]) for k, v in json.load(sys.stdin).items()]')
web() { ssh "${S[@]}" "ops@${IP[web1]}" "$@"; }
db()  { ssh "${S[@]}" "ops@${IP[db1]}" "$@"; }
GRESKE=0
tvrdi() { local opis="$1"; shift; if "$@"; then echo "  ok: $opis"; else echo "  NIJE OK: $opis"; GRESKE=$((GRESKE + 1)); fi; }

marker="ao10-$(date +%s)-$RANDOM"
echo "== AO-10: perzistencija podataka baze"
echo "-- 1. unos podatka kroz aplikaciju: '$marker'"
tvrdi "upis (HTTP 201)" test "$(web "curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{\"text\":\"$marker\"}' http://localhost/api/notes")" = 201

id_prije="$(db "sudo docker inspect -f '{{.Id}}' ruo-db-1" | cut -c1-12)"
echo "-- 2a. ponovno kreiranje kontejnera baze (docker compose up --force-recreate)"
db "cd /opt/ruo && sudo docker compose --profile db up -d --force-recreate --wait db" >/dev/null 2>&1
id_poslije="$(db "sudo docker inspect -f '{{.Id}}' ruo-db-1" | cut -c1-12)"
tvrdi "kontejner je nov (ID $id_prije -> $id_poslije)" test "$id_prije" != "$id_poslije"
tvrdi "podatak je i dalje tu" grep -q "$marker" <<< "$(web 'curl -s http://localhost/api/notes')"

echo "-- 2b. kontejner obrisan potpuno (docker rm -f), pa ponovo napravljen"
db "sudo docker rm -f ruo-db-1 >/dev/null && cd /opt/ruo && sudo docker compose --profile db up -d --wait db" >/dev/null 2>&1
tvrdi "podatak je i dalje tu" grep -q "$marker" <<< "$(web 'curl -s http://localhost/api/notes')"

echo "-- 3. gdje su podaci: zaseban disk VM-a, ne sloj kontejnera"
db "findmnt -no SOURCE,TARGET,FSTYPE /srv/pgdata; sudo docker inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}' ruo-db-1 | grep pgdata" | sed 's/^/     /'

echo; [ "$GRESKE" = 0 ] && echo "Perzistencija: podaci su preživjeli ponovno kreiranje kontejnera baze." || { echo "Perzistencija: neuspjelih provjera: $GRESKE"; exit 1; }
