# Troslojna aplikacija kao kod

Projektni zadatak iz predmeta **Računarstvo u oblaku** (Politehnički fakultet, Univerzitet u Zenici, 2026/27).

Infrastruktura za web aplikaciju s frontendom, backendom i bazom podataka, opisana isključivo kodom: virtuelne mašine (Terraform + libvirt), početna konfiguracija (cloud-init), konfiguracija servera (Ansible), kontejneri (Docker), segmentirana mreža (libvirt `route` mreže + nftables) i DNS (BIND, zapisi kao Terraform resursi).

> **Status:** u izradi. Faza 1 (aplikacija i lokalni razvoj) je gotova. Infrastruktura (Packer, Terraform, Ansible, DNS) dolazi u sljedećim fazama, a ovaj README se dopunjava uz svaku od njih.

## Aplikacija: „Bilješke"

| Sloj | Tehnologija | Kontejner | Adresira sljedeći sloj |
|---|---|---|---|
| frontend | nginx 1.27 (statični HTML/JS + reverse proxy `/api/`) | `ruo/frontend` | `backend.<zona>:8000` |
| backend | Python 3.12, FastAPI, psycopg 3 | `ruo/backend` | `db.<zona>:5432` |
| baza | PostgreSQL 17 | `postgres:17-alpine` | — |

API: `GET /api/healthz` (liveness), `GET /api/readyz` (baza odgovara), `GET /api/notes`, `POST /api/notes` (`{"text": "..."}`), dokumentacija na `/api/docs`.

Principi u kodu aplikacije:
- **nijedna IP adresa**: slojevi se adresiraju DNS imenima iz okruženja (AO-7);
- **lozinka iz datoteke** (`*_PASSWORD_FILE`), nikad iz varijable okruženja (AO-9);
- **backend ne radi kao root**, korijenski fajl sistem je samo za čitanje, a sve Linux capabilities su odbačene;
- šema baze se pravi samo nad praznim direktorijem podataka, pa ponovno kreiranje kontejnera ne dira podatke (AO-10).

## Lokalni razvoj (bez VM-ova)

`app/compose.dev.yaml` pokreće sva tri sloja na jednom računaru. Segmenti su Docker mreže (`web`, `app` i `db`, pri čemu su `app` i `db` internal), a kontejner je samo na mrežama koje mu trebaju. Produkcijski raspored je drugačiji (svaki sloj na svom VM-u, vidi DO-2), a opisan je u `app/compose.yaml`.

```bash
make dev-up        # lozinka u .secrets/ (ako ne postoji), build, pokretanje, čekanje zdravlja
make dev-test      # provjera s kraja na kraj preko frontenda: http://localhost:8080
make dev-persist   # AO-10: upis, ponovno kreiranje kontejnera baze, podatak je i dalje tu
make dev-clean     # brisanje kontejnera i volumena
```

## Preduslovi

- Windows 11 + WSL2 (Ubuntu), `systemd=true`, nested virtualizacija (`/dev/kvm` u WSL-u).
- Repozitorij mora biti u Linux fajl sistemu (`~/`), **ne** u `/mnt/c/...`: Ansible ignoriše `ansible.cfg` u direktoriju u koji svi mogu pisati.
- Docker Engine **u WSL distribuciji** (ne Windows binarka Docker Desktopa). `make check` upozorava ako `docker` pokazuje na `/mnt/c/...`.
- Alati: `make check`.

## Struktura repozitorija

```
app/          frontend/, backend/, db/init/, compose.yaml (produkcija), compose.dev.yaml (razvoj)
tests/        app.sh (s kraja na kraj); slijede izolacija, DNS, perzistencija, idempotentnost
docs/adr/     zapisi dizajnerskih odluka DO-1 … DO-9
Makefile      ulaz u sve korake (make help)
```

<!-- Sekcije koje se dodaju po fazama (zahtjevi projektnog zadatka):
  - dijagram stvarnog rasporeda, plan adresiranja, način izolacije
  - upute od praznog računara: podizanje, test, uklanjanje
  - drift (terraform plan + ispravka)
  - izlaz drugog Ansible izvršavanja (changed=0)
  - izlaz testova (izolacija, dig, aplikacija)
-->
