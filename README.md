# Troslojna aplikacija kao kod

Projektni zadatak iz predmeta **Računarstvo u oblaku** (Politehnički fakultet, Univerzitet u Zenici, 2026/27).

Infrastruktura za web aplikaciju s frontendom, backendom i bazom podataka, opisana isključivo kodom: virtuelne mašine (Terraform + libvirt), početna konfiguracija (cloud-init), konfiguracija servera (Ansible), kontejneri (Docker), segmentirana mreža (libvirt `route` mreže + nftables) i DNS (BIND, zapisi kao Terraform resursi).

> **Status:** u izradi. Gotove su faza 1 (aplikacija i lokalni razvoj) i faza 2 (zlatna slika i VM-ovi). Slijede Ansible (konfiguracija, vatrozid, DNS server), DNS zapisi i isporuka aplikacije, a ovaj README se dopunjava uz svaku fazu.

## Infrastruktura (faza 2)

| Korak | Alat | Rezultat |
|---|---|---|
| `make image` | Packer | zlatna slika `build/image-<hash>/ruo-base.qcow2`: Ubuntu 24.04 cloud slika + Docker, nftables, BIND. Gradi se samo kad se promijeni mapa `packer/` (DO-4). |
| `make infra` | Terraform (`terraform/vm`) | 4 libvirt mreže u `route` modu, 4 VM-a, zaseban disk za podatke na db1, a za Ansible generisani inventory i `known_hosts` (AO-3, DO-6). |
| cloud-init | `cloud-init/*.tftpl` | korisnik `ops` samo s ključem, lozinke onemogućene, ključ servera iz Terraforma, statička adresa i resolver (AO-4). |
| `make test-vm` | `tests/vm.sh` | `terraform plan` bez promjena; po VM-u hostname, `cloud-init: done`, adresa iz plana, SSH ključem prolazi, a lozinkom je odbijen. |

### Plan adresiranja

Jedini IP literal u kodu je `project_cidr = "10.20.0.0/16"` (`terraform/vm/variables.tf`). Podmreže se računaju sa `cidrsubnet(project_cidr, 8, n)`, a adrese sa `cidrhost(podmreža, hostnum)`. `make test-ip` provjerava da drugih literala nema (AO-7).

| Segment | Podmreža | Gateway (host) | VM | Adresa | Uloga |
|---|---|---|---|---|---|
| infra | 10.20.0.0/24 | 10.20.0.1 | ns1 | 10.20.0.53 | autoritativni DNS (BIND) |
| web | 10.20.1.0/24 | 10.20.1.1 | web1 | 10.20.1.10 | frontend, jedini ulaz izvana |
| app | 10.20.2.0/24 | 10.20.2.1 | app1 | 10.20.2.10 | backend |
| db | 10.20.3.0/24 | 10.20.3.1 | db1 | 10.20.3.10 | baza + disk za podatke (`vdb`) |
| klijent | 10.20.255.0/30 | 10.20.255.1 | (namespace) | 10.20.255.2 | simulirani internet |

Adrese su statičke (cloud-init `network-config`, netplan), a na projektnim mrežama nema DHCP-a ni dnsmasq-a. Resolver svakog VM-a je ns1.

```bash
make infra        # slika (ako treba) + VM-ovi
make test-vm      # AO-3 i AO-4
make infra-plan   # nakon apply: "No changes"
make infra-destroy
```

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
packer/       zlatna slika VM-ova (ruo-base.pkr.hcl, seed/, scripts/provision.sh)
terraform/vm/ mreže, diskovi, VM-ovi, ključevi servera, generisani inventory (AO-3)
cloud-init/   user-data, network-config, meta-data šabloni (AO-4)
tests/        app.sh, vm.sh, no-ip-literals.sh; slijede izolacija, DNS, perzistencija, idempotentnost
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
