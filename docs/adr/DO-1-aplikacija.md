# DO-1: Aplikacija i tehnologije slojeva

Status: prihvaćeno

## Kontekst

Projekat ocjenjuje infrastrukturu, a ne aplikaciju. Aplikacija ipak mora ispuniti tri uslova. Mora imati tri zasebna sloja, svaki u svom kontejneru, s tokom zahtjeva isključivo frontend → backend → baza (AO-1). Mora stvarno upisivati podatke, da bi se moglo dokazati da oni preživljavaju ponovno kreiranje kontejnera baze (AO-10). Svaki sloj mora adresirati sljedeći DNS imenom, nikad IP adresom (AO-7).

Na odbrani se može pitati za bilo koji fajl, pa je svaka linija aplikacije gradivo koje se mora znati objasniti.

## Razmotrene opcije

1. Gotova open-source aplikacija (CMS, blog, forum).
2. Vlastita minimalna aplikacija: nginx + Python Flask/gunicorn + PostgreSQL (kao primjer s3/p4).
3. Vlastita minimalna aplikacija: nginx + Python FastAPI/uvicorn + PostgreSQL.
4. Ista struktura s MySQL ili MongoDB bazom.

## Odluka

Opcija 3: vlastita aplikacija „Bilješke".

| Sloj | Tehnologija | Uloga |
|---|---|---|
| frontend | nginx 1.27.5 (zvanična slika), statični HTML/JS bez build koraka | jedini ulaz; poslužuje stranicu i prosljeđuje `/api/` na `backend.<zona>:8000` |
| backend | Python 3.12.16, FastAPI, psycopg 3 + connection pool | REST API: `GET/POST /api/notes`, `GET /api/healthz` (liveness), `GET /api/readyz` (baza odgovara) |
| baza | PostgreSQL 17.12 (zvanična alpine slika) | tabela `notes`; šema iz `docker-entrypoint-initdb.d`, izvršava se samo nad praznim direktorijem podataka |

## Obrazloženje i posljedice

Šta se dobija:
- **Kod koji se može objasniti red po red.** Backend ima oko 140 redova, frontend jednu stranicu.
- **Smisleno dokazive AO.** Upis i čitanje bilješke prolaze kroz sva tri sloja (AO-1). Podatak u PostgreSQL-u preživljava `docker compose up --force-recreate` i `docker rm -f` (AO-10).
- **Konfiguracija samo iz okruženja.** Adrese su DNS imena (`DB_HOST=db.ruo.internal`), a lozinka se čita iz datoteke (`DB_PASSWORD_FILE`), jer se varijable okruženja vide u `docker inspect`.
- **Odvojeni liveness i readiness** (obrazac iz s3/p4). Pad baze ne izaziva restart backenda. Pool provjerava vezu pri izdavanju, pa nakon ponovnog kreiranja kontejnera baze backend sam uspostavlja nove veze.
- **nginx razrješava ime backenda u toku rada** (`resolver` iz `/etc/resolv.conf`, ime u varijabli). Promjena DNS zapisa važi bez restarta frontenda.
- **PostgreSQL** je relacijska baza s transakcijama i gradivo predmeta; Python je jezik primjera s vježbi. FastAPI daje validaciju ulaza (prazna bilješka: 422) i OpenAPI dokumentaciju.

Šta se gubi:
- Aplikacija nije „impresivna", ali se ona i ne boduje. Gotova open-source aplikacija bi donijela dodatne servise (keš, redovi poruka, migracije) koji bi zamutili troslojnu strukturu i povećali gradivo za odbranu.
- PostgreSQL 18 nije izabran jer zvanična slika verzije 18 mijenja podrazumijevani `PGDATA` i mjesto volumena. Verzija 17 zadržava klasičan `/var/lib/postgresql/data`.
