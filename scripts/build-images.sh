#!/usr/bin/env bash
# Izgradnja i pakovanje slika kontejnera (DO-5): build JEDNOM na kontrolnom čvoru, a isporuka na
# VM-ove kao arhive (docker save). VM-ovi nemaju izlaz na internet, pa ne povlače ništa s registryja.
#
# Oznaka (APP_TAG) je hash sadržaja app/frontend i app/backend: ista aplikacija = ista oznaka,
# pa ponovni make all ne gradi i ne isporučuje ništa novo (idempotentnost).
# Rezultat: build/images/*.tar i build/images/manifest.yml (čita ga ansible/deploy.yml).
set -euo pipefail
cd "$(dirname "$0")/.."

# Baza: zvanična slika zaključana digestom (PostgreSQL 17.12). Lokalno dobija oznaku s tačnom verzijom.
DB_REF="postgres:17-alpine@sha256:a77aa70e641402a21411b92b721c58d10f23b50ae5fdd2333efd22d166e1e5f7"
DB_IMAGE="postgres:17.12-alpine"

OUT=build/images
APP_TAG="$(find app/frontend app/backend -type f | LC_ALL=C sort | xargs cat | sha256sum | cut -c1-12)"
mkdir -p "$OUT"

sacuvaj() { # slika datoteka
  if [ -s "$OUT/$2" ]; then echo "  postoji: $OUT/$2"; else docker save -o "$OUT/$2.tmp" "$1" && mv "$OUT/$2.tmp" "$OUT/$2"; echo "  sačuvano: $OUT/$2 ($(du -h "$OUT/$2" | cut -f1))"; fi
}

for s in frontend backend; do
  if ! docker image inspect "ruo/$s:$APP_TAG" >/dev/null 2>&1; then
    echo "== build ruo/$s:$APP_TAG"
    docker build -q -t "ruo/$s:$APP_TAG" "app/$s" >/dev/null
  fi
  sacuvaj "ruo/$s:$APP_TAG" "$s-$APP_TAG.tar"
done

docker image inspect "$DB_REF" >/dev/null 2>&1 || docker pull -q "$DB_REF" >/dev/null
docker tag "$DB_REF" "$DB_IMAGE"
sacuvaj "$DB_IMAGE" "db-${DB_IMAGE//[:\/]/_}.tar"

# stare arhive (druga oznaka) nisu potrebne
find "$OUT" -name '*.tar' ! -name "*-$APP_TAG.tar" ! -name "db-*" -delete

cat > "$OUT/manifest.yml" <<EOF
# GENERISANO: scripts/build-images.sh. Šta se isporučuje na VM-ove (ansible/deploy.yml).
app_tag: "$APP_TAG"
app_slike:
  frontend: { ime: "ruo/frontend:$APP_TAG", arhiva: "$PWD/$OUT/frontend-$APP_TAG.tar" }
  backend:  { ime: "ruo/backend:$APP_TAG",  arhiva: "$PWD/$OUT/backend-$APP_TAG.tar" }
  db:       { ime: "$DB_IMAGE", arhiva: "$PWD/$OUT/db-${DB_IMAGE//[:\/]/_}.tar" }
EOF
echo "slike: APP_TAG=$APP_TAG, baza=$DB_IMAGE"
