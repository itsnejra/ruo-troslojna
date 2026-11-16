# DO-5: Izgradnja i distribucija slika kontejnera

Status: prihvaćeno

## Kontekst

Svaki sloj radi u svom kontejneru (AO-1). VM-ovi nemaju izlaz na internet (DO-2), pa ne mogu povlačiti slike s Docker Huba niti izvršavati `pip install` pri izgradnji. Tajne ne smiju završiti u slikama (AO-9). Ponovni `make all` ne smije ništa mijenjati.

## Razmotrene opcije

1. Build na ciljnom VM-u (`docker compose build`, kao s3/p4).
2. Build lokalno + privatni registry (`registry:2`) na infra VM-u; VM-ovi povlače slike iz njega (model ECR/ACR).
3. Build lokalno + isporuka kao arhiva (`docker save` → Ansible `copy` → `docker load`).

## Odluka

Opcija 3 (`scripts/build-images.sh`, `make images`, `make deploy`).

- **Backend:** multi-stage Dockerfile. Faza 1 instalira zavisnosti, faza 2 je slim runtime bez alata za build. Proces radi kao UID 10001, a slika ima `HEALTHCHECK`.
- **Frontend:** nginx + statične datoteke + šablon konfiguracije koji se popunjava pri pokretanju, pa ista slika radi i lokalno i na VM-u.
- **Bazne slike su zaključane digestom:**
  - `python:3.12-slim@sha256:5e2b…` (3.12.16)
  - `nginx:1.27-alpine@sha256:6564…` (1.27.5)
  - `postgres:17-alpine@sha256:a77a…` (17.12)
- **Oznaka (`APP_TAG`)** je hash sadržaja `app/frontend` i `app/backend`: ista aplikacija daje istu oznaku.
- **Isporuka** (rola `app`): `copy` prenosi arhivu samo kad se promijeni checksum; `docker_image` (`source: load`) je učitava samo ako slika s tom oznakom ne postoji; compose koristi `pull_policy: never`.

## Obrazloženje i posljedice

Šta se dobija:
- **„Build once, deploy many".** Isti artefakt ide na svako okruženje; ono što je testirano lokalno (`make dev-up`) je bajt za bajt isto što radi na VM-u.
- **VM-ovi nemaju ni internet ni alate za build** (kompajler, pip), pa je manja površina napada.
- **Reproducibilnost.** Digest garantuje istu baznu sliku i kad se tag `3.12-slim` pomakne na noviju verziju.
- **Idempotentnost.** Drugi `make deploy` je `changed=0`, jer se ništa ne prenosi, ne učitava i ne restartuje.
- **Nema dodatnog servisa koji treba štititi.** Registry bi tražio TLS ili `insecure-registries`, autentifikaciju i vlastiti vatrozid.

Šta se gubi:
- Pri transferu nema deduplikacije slojeva: prenosi se cijela arhiva (frontend ~20 MB, backend ~52 MB, baza ~113 MB). Ublaženo slim/alpine slikama i transferom kroz lokalnu virtuelnu mrežu.
- Kontrolni čvor mora imati Docker (u WSL-u, ne Docker Desktop).
- Oznaka nije semantička verzija (nije „v1.2"), nego hash. Za ovaj projekat je to prednost (determinizam); u produkciji bi se uz hash čuvala i oznaka verzije.
- Registry ostaje put evolucije: CI gradi sliku i radi push, a okruženja povlače po digestu.
