#!/usr/bin/env bash
# PDF za predaju: naslovna strana, opis aplikacije i arhitekture, tabela DO-1..DO-9 i 9 ADR-ova.
# Izvor je isti docs/ADR.md kao u repozitoriju, pa PDF i repozitorij ne mogu reći različite stvari.
#
#   Markdown -> HTML: pandoc (zvanična Docker slika, zaključana digestom)
#   HTML -> PDF:      Chromium/Chrome ako postoji, inače Microsoft Edge s Windowsa (WSL2)
#
#   REPO_URL=https://github.com/<korisnik>/ruo-troslojna make pdf
set -euo pipefail
cd "$(dirname "$0")/.."

PANDOC="pandoc/core:3.6@sha256:5b8a29d9b70d5d8ca766e5d1dcfc41916b23ab79276a80527be70516110f4c1e"
OUT=build/pdf
IME=RuO-projekat-troslojna-aplikacija
PREDAJA=RuO-projekat-Nejra-Smajlovic.pdf   # ime PDF-a za predaju, u docs/
AUTOR="${AUTOR:-$(git config user.name)}"
REPO_URL="${REPO_URL:-$(git remote get-url origin 2>/dev/null | sed -E 's#^git@([^:]+):#https://\1/#; s#\.git$##' || true)}"
REPO_URL="${REPO_URL:-(link na repozitorij)}"
mkdir -p "$OUT"

# naslovna strana: autor i link na repozitorij
sed -e "s#@@AUTOR@@#${AUTOR}#g" -e "s#@@REPO@@#${REPO_URL}#g" docs/pdf/uvod.md > "$OUT/uvod.md"
cp docs/pdf/stil.css "$OUT/stil.css"
# ADR-ovi bez uvodne tabele (ona je već u uvod.md) i bez razdjelnika: svaki ADR počinje novom stranom
sed -n '/^# DO-1:/,$p' docs/ADR.md | sed '/^---$/d' > "$OUT/adr.md"

docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/data" -w /data "$PANDOC" \
  "$OUT/uvod.md" "$OUT/adr.md" \
  --standalone --from gfm+yaml_metadata_block --to html5 \
  --metadata title="Troslojna aplikacija kao kod" --metadata lang=bs \
  --css "$OUT/stil.css" --embed-resources \
  --output "$OUT/$IME.html"
echo "HTML: $OUT/$IME.html"

# HTML -> PDF (bez zaglavlja i podnožja preglednika)
FLAGS=(--headless --disable-gpu --no-pdf-header-footer --print-to-pdf-no-header)
if b="$(command -v chromium || command -v chromium-browser || command -v google-chrome || true)" && [ -n "$b" ]; then
  "$b" "${FLAGS[@]}" --print-to-pdf="$OUT/$IME.pdf" "file://$PWD/$OUT/$IME.html" 2>/dev/null
else
  EDGE="/mnt/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
  [ -x "$EDGE" ] || { echo "Nema Chromiuma ni Edgea: HTML je gotov ($OUT/$IME.html), PDF napraviti štampom iz preglednika."; exit 1; }
  # Edge je Windows program: radi s Windows putanjama, pa ide preko privremenog direktorija na C:
  WTMP="$(wslpath "$(cmd.exe /c 'echo %TEMP%' 2>/dev/null | tr -d '\r')")/ruo-pdf"
  mkdir -p "$WTMP"; cp "$OUT/$IME.html" "$WTMP/"
  "$EDGE" "${FLAGS[@]}" --print-to-pdf="$(wslpath -w "$WTMP/$IME.pdf")" "file:///$(wslpath -m "$WTMP/$IME.html")" 2>/dev/null || true
  for _ in $(seq 30); do [ -s "$WTMP/$IME.pdf" ] && break; sleep 1; done
  cp "$WTMP/$IME.pdf" "$OUT/$IME.pdf"; rm -rf "$WTMP"
fi
[ -s "$OUT/$IME.pdf" ] && echo "PDF:  $OUT/$IME.pdf ($(du -h "$OUT/$IME.pdf" | cut -f1)), repozitorij u dokumentu: $REPO_URL"

# Kopija u repozitoriju (docs/), da se PDF vidi i na GitHubu. Nakon izmjene ADR-a: make pdf + commit.
cp "$OUT/$IME.pdf" "docs/$PREDAJA"
echo "kopija: docs/$PREDAJA"
