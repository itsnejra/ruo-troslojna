# Troslojna aplikacija kao kod

Projektni zadatak iz predmeta **Računarstvo u oblaku** (Politehnički fakultet, Univerzitet u Zenici, 2026/27).

Infrastruktura za web aplikaciju s frontendom, backendom i bazom podataka, opisana isključivo kodom: virtuelne mašine (Terraform + libvirt), početna konfiguracija (cloud-init), konfiguracija servera (Ansible), kontejneri (Docker), segmentirana mreža (libvirt `route` mreže + nftables) i DNS (BIND, zapisi kao Terraform resursi).

> **Status:** u izradi. Gotove su faze 1–5: aplikacija, zlatna slika i VM-ovi, Ansible (ruter, vatrozid, Docker, DNS server), DNS zapisi iz Terraforma i isporuka aplikacije. Slijede `make all` / `make destroy` od nule i dokumentacija (ADR, PDF).

## Isporuka aplikacije (faza 5)

| Korak | Šta radi |
|---|---|
| `make images` | gradi `ruo/frontend` i `ruo/backend` **jednom, na kontrolnom čvoru**; bazne slike su zaključane digestom (nginx 1.27.5, Python 3.12.16, PostgreSQL 17.12); sve tri slike se pakuju u arhive (`build/images/`). Oznaka slike je hash sadržaja `app/`, pa ista aplikacija znači istu oznaku i nema ponovne isporuke (DO-5). |
| `make deploy` | `ansible/deploy.yml`, redom baza → backend → frontend, uz čekanje da svaki sloj postane zdrav |

Rola `app` na svakom VM-u:
- **db1:** formatira disk `/dev/vdb` (samo ako je prazan), montira ga na `/srv/pgdata` i postavlja `pg_hba.conf`, koji pušta samo app podmrežu s SCRAM lozinkom (treći nivo zaštite);
- **tajne:** lozinka baze je datoteka 0400 čiji je vlasnik korisnik procesa u kontejneru (UID 70 za postgres, 10001 za backend), a kontejner je čita preko `*_FILE` (AO-9);
- **slike:** arhivu prenosi samo kad se promijeni, a u Docker je učitava samo ako ta oznaka ne postoji;
- **pokretanje:** `docker compose --profile <sloj>` nad istim `compose.yaml` na svim VM-ovima. Mreža je `host`, pa **nijedan kontejner nema objavljen port** (AO-6).

```bash
make deploy        # drugi put: changed=0
make test-app      # AO-1: iz namespace-a klijenta: www.ruo.internal -> frontend -> backend -> baza (sudo)
make test-persist  # AO-10: unos -> docker compose up --force-recreate / docker rm -f -> podatak je tu
```

## DNS zapisi kao kod (faza 4)

`terraform/dns` upravlja zapisima preko RFC 2136 (DNS UPDATE) potpisanog TSIG ključem (AO-8). Adrese čita iz outputa `terraform/vm` (`terraform_remote_state`), a TSIG tajne dobija iz vaulta kroz `TF_VAR_*` (`scripts/tf-dns.sh`), tako da nikad nisu u datoteci.

| Zapis | Vrsta | Vlasnik |
|---|---|---|
| SOA, NS, `ns1` (glue) | početno stanje zone | Ansible (rola `bind`, samo pri nastanku zone) |
| `frontend`, `backend`, `db` | A, servisna imena koja koristi aplikacija | Terraform (`var.servisi`; više VM-ova = round-robin) |
| `web1`, `app1`, `db1` | A, imena hostova | Terraform |
| `www` | CNAME → `frontend` | Terraform (`var.aliasi`) |
| `@` | TXT `managed-by=terraform` | Terraform |
| PTR za sve VM-ove | reverzna zona `20.10.in-addr.arpa` | Terraform, **drugi ključ** (`tf-ptr`) |

**Prava ključeva (najmanja prava):** `tf-ruo` smije samo zonu `ruo.internal` i samo A/AAAA/CNAME/TXT/SRV (ne NS ni SOA). `tf-ptr` smije samo PTR u reverznoj zoni. `make test-dns` pokušava sve ostalo i očekuje `REFUSED`.

**Sat VM-ova.** TSIG potpis sadrži vrijeme, a server odbija poruke s razlikom većom od 5 minuta (`BADTIME`). Pošto VM-ovi nemaju izlaz na internet, ne mogu koristiti javne NTP servere. Zato `chrony` u svakom VM-u (dio slike) uzima vrijeme direktno od hipervizora preko `ptp_kvm` (`refclock PHC`), bez mreže. `make test-vm` provjerava da je razlika najviše 2 s.

```bash
make dns          # zapisi (drugi put: No changes)
make test-dns     # dig, PTR, REFUSED/NXDOMAIN, AXFR, prava ključeva, plan bez promjena
make drift-dns    # nsupdate mimo koda -> terraform plan vidi razliku -> apply ispravlja
```

### Drift (izlaz `make drift-dns`)

```text
== 1. DRIFT: nsupdate briše backend i mijenja adresu za db (mimo Terraforma)
backend.ruo.internal -> ''   (nema ga)
db.ruo.internal      -> 10.20.3.99   (pogrešna adresa)

== 2. terraform plan: Terraform vidi razliku (exit 2 = ima promjena)
  # dns_a_record_set.servis["backend"] will be created
  # dns_a_record_set.servis["db"] will be updated in-place
      ~ addresses = [
          - "10.20.3.99",
          + "10.20.3.10",
Plan: 1 to add, 1 to change, 0 to destroy.

== 3. terraform apply: stvarnost se vraća na stanje iz koda
Apply complete! Resources: 1 added, 1 changed, 0 destroyed.
backend.ruo.internal -> 10.20.2.10
db.ruo.internal      -> 10.20.3.10

== 4. terraform plan ponovo: bez promjena
No changes. Your infrastructure matches the configuration.
```

Ograničenje koje treba znati: Terraform vidi samo zapise koje je sam napravio. Zapis koji neko doda ručno, a nije u kodu, plan ne prijavljuje. Zato je zona dodijeljena jednom vlasniku-alatu, a cijela zona se može pregledati sa `dig AXFR` uz ključ.

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

## Konfiguracija i izolacija (faza 3)

`make config` pokreće `ansible/config.yml` (AO-5). Traži sudo lozinku hosta, jer rola `router` mijenja host.

| Rola | Gdje | Šta radi |
|---|---|---|
| `router` | host (WSL) | tabela `inet ruo3t`: default deny **samo** za promet projektnih sučelja (tuđi promet na hostu ne dira); namespace `ruo-klijent` kao „internet" |
| `common` | svi VM-ovi | čeka SSH i cloud-init, `/etc/ruo` |
| `firewall` | svi VM-ovi | nftables `input`: SSH samo s hosta, ulaz iz politike, `flush ruleset` (VM je u potpunosti naš) |
| `docker` | web, app, db | `daemon.json`: `iptables: false`, `bridge: none`, `ip-forward: false` (kontejneri koriste mrežu VM-a) |
| `bind` | ns1 | autoritativni BIND: `ruo.internal` i `20.10.in-addr.arpa`, `recursion no`, AXFR samo uz ključ, TSIG ključ po zoni i samo za navedene tipove zapisa |

**Politika mreže je podatak** (`ansible/inventory/group_vars/all/main.yml`, `mreza_politika`). Iz istog popisa nastaju pravila rutera i ulazna pravila VM-ova, pa se dva nivoa zaštite ne mogu razići:

| Od | Do | Port |
|---|---|---|
| klijent (internet) | web | tcp/80 |
| web | app | tcp/8000 |
| app | db | tcp/5432 |
| klijent, web, app, db | infra | tcp+udp/53 |
| sve ostalo | | **odbijeno** (i izlaz segmenata prema internetu) |

**Tajne** (`make secrets`, AO-9): `.vault_pass` i `ansible/inventory/group_vars/all/vault.yml` (AES256) se generišu pri prvom pokretanju i nisu u Gitu. U Gitu je samo `vault.yml.example`.

```bash
make config           # Ansible (sudo lozinka hosta)
make config           # drugi put: changed=0 (idempotentnost)
make test-isolation   # AO-6: matrica povezivosti (sudo)
```

## Pokretanje infrastrukture

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
- Docker Engine **u WSL distribuciji** (ne Windows binarka Docker Desktopa): `sudo apt-get install -y docker.io docker-compose-v2 docker-buildx`. `make check` upozorava ako `docker` pokazuje na `/mnt/c/...`.
- Alati: `make check`.

## Struktura repozitorija

```
app/          frontend/, backend/, db/init/, compose.yaml (produkcija), compose.dev.yaml (razvoj)
packer/       zlatna slika VM-ova (ruo-base.pkr.hcl, seed/, scripts/provision.sh)
terraform/vm/ mreže, diskovi, VM-ovi, ključevi servera, generisani inventory (AO-3)
terraform/dns/ DNS zapisi: servisi, hostovi, CNAME, PTR (AO-8)
ansible/      config.yml, teardown.yml, role: router, common, firewall, docker, bind
scripts/      tajne (secrets.sh, vault-get.sh), tf-dns.sh, drift-dns.sh, tf-retry.sh
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
