#!/usr/bin/env bash
# Provjera aplikacije s kraja na kraj (AO-1): klijent -> frontend -> backend -> baza.
# Zahtjev ide isključivo preko frontenda; ako prođe upis i čitanje, rade sva tri sloja.
#
#   tests/app.sh http://localhost:8080          razvojni compose (make dev-test)
#   tests/app.sh http://www.ruo.internal        produkcija, iz namespace-a ruo-klijent
set -uo pipefail

BASE="${1:?Upotreba: $0 <URL frontenda>}"
GRESKE=0
tvrdi() { local opis="$1"; shift; if "$@"; then echo "  ok: $opis"; else echo "  NIJE OK: $opis"; GRESKE=$((GRESKE + 1)); fi; }
kod() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@"; }

echo "== aplikacija: $BASE"
tvrdi "frontend živ (/healthz)" test "$(kod "$BASE/healthz")" = 200
tvrdi "backend spreman i vidi bazu (/api/readyz)" test "$(kod "$BASE/api/readyz")" = 200

marker="test-$(date +%s)-$RANDOM"
tvrdi "upis bilješke (POST /api/notes -> 201)" \
  test "$(kod -X POST -H 'Content-Type: application/json' -d "{\"text\":\"$marker\"}" "$BASE/api/notes")" = 201
lista="$(curl -s --max-time 5 "$BASE/api/notes")"
tvrdi "upisana bilješka se čita iz baze" grep -q "$marker" <<< "$lista"
tvrdi "prazna bilješka se odbija (422)" \
  test "$(kod -X POST -H 'Content-Type: application/json' -d '{"text":""}' "$BASE/api/notes")" = 422

echo "  odgovorio backend: $(grep -o '"served_by":"[^"]*"' <<< "$lista" | head -1)"
echo; [ "$GRESKE" = 0 ] && echo "Aplikacija: sve provjere su prošle." || { echo "Aplikacija: neuspjelih provjera: $GRESKE"; exit 1; }
