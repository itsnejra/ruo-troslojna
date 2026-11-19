# Troslojna aplikacija kao kod

Projektni zadatak iz predmeta **Računarstvo u oblaku**, Politehnički fakultet Univerziteta u Zenici, akademska 2026/27.
Autor: Nejra Smajlović.

Infrastruktura za web aplikaciju s frontendom, backendom i bazom podataka, opisana isključivo kodom:

| Sloj infrastrukture | Alat |
|---|---|
| zlatna slika VM-ova | Packer |
| virtuelne mašine, mreže i diskovi | Terraform + libvirt/KVM |
| početna konfiguracija VM-a | cloud-init |
| konfiguracija servera | Ansible |
| aplikacija | Docker |
| segmentirana mreža | libvirt `route` mreže + nftables |
| DNS | BIND, a zapisi kao Terraform resursi |

Okruženje se podiže i uklanja jednom naredbom, bez ručnih koraka. Svaka obavezna arhitektonska odluka (AO) ima automatski test.

```bash
make destroy && make all && make test && make all     # tok odbrane
```

**Sadržaj:**
[1. Aplikacija i arhitektura](#1-aplikacija-i-arhitektura) ·
[2. Dizajnerske odluke](#2-dizajnerske-odluke) ·
[3. Adresiranje i izolacija](#3-plan-adresiranja-i-izolacija-slojeva) ·
[4. Pokretanje od praznog računara](#4-pokretanje-od-praznog-računara) ·
[5. DNS](#5-dns-zona-i-zapisi-kao-kod) ·
[6. Drift](#6-drift) ·
[7. Idempotentnost](#7-idempotentnost) ·
[8. Izlaz testova](#8-izlaz-testova) ·
[9. Tajne](#9-tajne) ·
[10. Struktura repozitorija](#10-struktura-repozitorija) ·
[11. Ograničenja](#11-poznata-ograničenja)

---

## 1. Aplikacija i arhitektura

**„Bilješke"** je vlastita, namjerno mala aplikacija (DO-1): na stranicu se upiše bilješka, ona se sačuva u bazu i prikaže u listi. Aplikacija nije predmet ocjenjivanja; služi da se kroz sva tri sloja prođe stvarnim zahtjevom i stvarnim podacima.

| Sloj | Tehnologija | Kontejner | Adresira sljedeći sloj |
|---|---|---|---|
| frontend | nginx 1.27.5, statični HTML/JS + reverse proxy `/api/` | `ruo/frontend` | `backend.ruo.internal:8000` |
| backend | Python 3.12.16, FastAPI, psycopg 3 | `ruo/backend` | `db.ruo.internal:5432` |
| baza | PostgreSQL 17.12 | `postgres:17.12-alpine` | — |

API: `GET /api/healthz` (liveness), `GET /api/readyz` (baza odgovara), `GET /api/notes`, `POST /api/notes`.

### Stvarni raspored

```
 Windows 11 ─ WSL2 Ubuntu (host = hipervizor KVM/libvirt + RUTER + kontrolni čvor: make, Terraform, Ansible, Packer, Docker)
 │
 │  ruo-klijent (netns, "internet")          nftables: table inet ruo3t
 │  10.20.255.2 ──veth── 10.20.255.1 (host)  forward: default DENY za promet projektnih sučelja
 │                              │
 │       ┌──────────────────────┼───────────────────────┬────────────────────────┐
 │  ruo-infra 10.20.0.0/24  ruo-web 10.20.1.0/24    ruo-app 10.20.2.0/24     ruo-db 10.20.3.0/24      (libvirt, mode=route)
 │   ┌──────────────┐        ┌──────────────┐        ┌──────────────┐        ┌───────────────────┐
 │   │ ns1  .53     │        │ web1 .10     │  8000  │ app1 .10     │  5432  │ db1 .10           │
 │   │ BIND 9.18    │        │ [frontend]   │ ─────▶ │ [backend]    │ ─────▶ │ [baza] PostgreSQL │
 │   │ ruo.internal │        │ nginx :80    │        │ FastAPI      │        │ disk vdb → pgdata │
 │   └──────────────┘        └──────────────┘        └──────────────┘        └───────────────────┘
 │     ▲ 53 (svi)               ▲ 80 (samo klijent)     ▲ 8000 (samo web)       ▲ 5432 (samo app)
 │
 └─ upravljanje: host → svi VM-ovi :22 (samo ključ) ; host → ns1:53 (Terraform, RFC 2136 + TSIG)
```

- Svaki sloj je na **svom VM-u** u **svom segmentu**. Kontejner koristi mrežu svog VM-a (`network_mode: host`), pa **nijedan kontejner nema objavljen port**, a nftables VM-a je jedini vatrozid na VM-u (DO-2).
- Promet između segmenata prolazi kroz host, gdje vatrozid propušta samo politikom dozvoljene tokove.
- Segmenti **nemaju izlaz na internet**: paketi su u zlatnoj slici, a slike kontejnera stižu s kontrolnog čvora.
- Sat VM-ova je sinhronizovan sa satom hipervizora (`chrony` + `ptp_kvm`), bez mreže (DO-4).

## 2. Dizajnerske odluke

Svaka odluka ima ADR u [`docs/adr/`](docs/adr/README.md).

| DO | Izabrana opcija |
|---|---|
| [DO-1](docs/adr/DO-1-aplikacija.md) Aplikacija | vlastita „Bilješke": nginx · FastAPI · PostgreSQL |
| [DO-2](docs/adr/DO-2-raspored-vm.md) VM-ovi | 4 VM-a (ns1, web1, app1, db1), libvirt `route` mreže, host je ruter s default deny, kontejneri na mreži VM-a |
| [DO-3](docs/adr/DO-3-adresiranje.md) Adresiranje | jedan literal `10.20.0.0/16`, `cidrsubnet`/`cidrhost`, statički preko netplana, bez DHCP-a |
| [DO-4](docs/adr/DO-4-bazna-slika.md) Bazna slika | Packer: Ubuntu 24.04 + Docker, nftables, BIND, chrony/ptp_kvm; cloud-init samo za instancu |
| [DO-5](docs/adr/DO-5-slike-kontejnera.md) Slike kontejnera | build jednom na kontrolnom čvoru, oznaka = hash koda, bazne slike po digestu, isporuka kao arhiva |
| [DO-6](docs/adr/DO-6-inventory.md) Inventory | Terraform generiše inventory, adresni plan i `known_hosts` |
| [DO-7](docs/adr/DO-7-ansible-role.md) Ansible | role po funkciji; mrežna politika kao podaci |
| [DO-8](docs/adr/DO-8-dns-zona.md) DNS zona | `ruo.internal` + reverzna; jedan vlasnik po zapisu; TSIG ključ po zoni i tipu |
| [DO-9](docs/adr/DO-9-tajne.md) Tajne | generisanje pri prvom pokretanju + ansible-vault; datoteke 0400; test historije |

## 3. Plan adresiranja i izolacija slojeva

Jedini IP literal u kodu je `project_cidr = "10.20.0.0/16"` u `terraform/vm/variables.tf`. Podmreže se računaju sa `cidrsubnet(project_cidr, 8, n)`, a adrese sa `cidrhost()`. `tests/no-ip-literals.sh` provjerava da drugih literala nema (AO-7).

| Segment | Podmreža | Gateway (host) | VM | Adresa | Uloga |
|---|---|---|---|---|---|
| infra | 10.20.0.0/24 | 10.20.0.1 | ns1 | 10.20.0.53 | autoritativni DNS |
| web | 10.20.1.0/24 | 10.20.1.1 | web1 | 10.20.1.10 | frontend, jedini ulaz izvana |
| app | 10.20.2.0/24 | 10.20.2.1 | app1 | 10.20.2.10 | backend |
| db | 10.20.3.0/24 | 10.20.3.1 | db1 | 10.20.3.10 | baza + disk za podatke |
| klijent | 10.20.255.0/30 | 10.20.255.1 | (namespace) | 10.20.255.2 | simulirani internet |

**Politika mreže je podatak** (`ansible/inventory/group_vars/all/main.yml`, `mreza_politika`). Default deny, a nabrajaju se samo dozvole, u smjeru uspostave veze:

| Od | Do | Port |
|---|---|---|
| klijent (internet) | web | tcp/80 |
| web | app | tcp/8000 |
| app | db | tcp/5432 |
| klijent, web, app, db | infra | tcp+udp/53 |
| sve ostalo | | **odbijeno**, i izlaz segmenata prema internetu |

Iz istog popisa nastaju tri nivoa zaštite, pa se ne mogu razići:
1. **ruter na hostu** (rola `router`, tabela `inet ruo3t`): osnovni lanac propušta tuđi promet (libvirt, Docker), a promet projektnih sučelja skače u lanac s default deny;
2. **vatrozid svakog VM-a** (rola `firewall`, `input` policy drop, SSH samo s hosta);
3. **za bazu još i `pg_hba.conf`**: samo app podmreža, samo baza i korisnik aplikacije, SCRAM lozinka.

Baza nema objavljen port (`docker ps`: `ports=[]`), a frontend nema mrežni put do baze. Oba se provjeravaju testom (odjeljak 8).

## 4. Pokretanje od praznog računara

### Preduslovi (jednom)

1. **WSL2 s Ubuntuom** (testirano: Ubuntu 26.04 na Windows 11, i9, 32 GB RAM). U PowerShellu: `wsl --install -d Ubuntu`.
2. **systemd i ugniježđena virtualizacija.** U `/etc/wsl.conf` treba `[boot] systemd=true`, a `ls /dev/kvm` u WSL-u mora postojati.
3. **Repozitorij u Linux fajl sistemu (`~/`), ne u `/mnt/c/...`.** Ansible ignoriše `ansible.cfg` u direktoriju u koji svi mogu pisati.
4. **Alati: `make setup`** (`scripts/setup.sh`, po uzoru na `00-setup.sh` predmeta). Instalira samo ono što nedostaje: Terraform, Packer, Ansible, libvirt/KVM, Docker Engine s compose i buildx, BIND alate (`dig`, `nsupdate`), nftables i socat. Uz to dodaje korisnika u grupe `libvirt`, `kvm` i `docker`, pravi libvirt pool `default` i instalira kolekcije Ansible-a. Idempotentna je: drugo pokretanje ne mijenja ništa.

```bash
make setup
```

Ako je korisnik dodan u nove grupe, treba se ponovo prijaviti (`wsl --shutdown` u PowerShellu). Isto okruženje daje i `00-setup.sh` iz repozitorija predmeta uz `INSTALL_DOCKER=1`, a `make check` pokazuje šta eventualno fali.

### Pokretanje na drugom računaru

Projekat ne zavisi ni od čega što nije u repozitoriju. Tajne, ključevi, zlatna slika, slike kontejnera i generisane datoteke prave se pri prvom `make all`.

**Okruženje:** isto kao za vježbe predmeta; `make setup` instalira sve što nedostaje. Zatim:

```bash
git clone https://github.com/itsnejra/ruo-troslojna.git ~/ruo-troslojna && cd ~/ruo-troslojna
```

```bash
make setup && make check && make all && make test
```

Ako se Ansible pokreće **direktno** (bez `make`), prvo treba `make secrets`. `ansible.cfg` čita lozinku vaulta iz `.vault_pass`, a ta datoteka u svježem klonu ne postoji dok je `make secrets` (ili `make all`) ne napravi.

| | Prvo pokretanje | Svako sljedeće |
|---|---|---|
| `make all` | **7 min 57 s** (izmjereno iz svježeg klona s GitHuba: Packer gradi zlatnu sliku, slike kontejnera se grade ispočetka), a nakon toga `make test`: svi testovi prolaze | ~1–2 min |
| internet | potreban (cloud slika, apt paketi u Packeru, bazne Docker slike, Terraform provideri) | nije potreban |
| sudo lozinka | `make all` jednom (rola `router`), `make test` jednom | isto |

**Resursi:** 4 VM-a trebaju ~4,5 GB RAM-a (`make check` upozorava ako nema dovoljno) i ~5 GB diska (slika, VM diskovi, arhive slika).

**Šta se mijenja na hostu** (sve uklanja `make destroy`):
- libvirt: mreže `ruo-infra/web/app/db`, VM-ovi `ruo-*` i diskovi `ruo-*` u poolu `default`;
- nftables tabela `inet ruo3t`, koja važi **samo** za promet projektnih sučelja; tuđa pravila ne dira;
- namespace `ruo-klijent` s veth parom, `/etc/ruo/`, `/usr/local/sbin/ruo-klijent-ns`, `/etc/sysctl.d/60-ruo.conf`.

Imena se ne sudaraju s labovima predmeta (tabela `inet ruo`, mreže 10.40/10.50).

**Testirane verzije:**

| Alat | Verzija |
|---|---|
| host | Ubuntu 26.04 u WSL2 (Windows 11) |
| Terraform | 1.17.1 |
| libvirt provider | 0.8.3 (zaključan) |
| Packer | 1.16.2 |
| ansible-core | 2.20.1 |
| Docker | 29.1.3 |
| QEMU | 10.2 |
| libvirt | 12.0 |

Kolekcije u `ansible/requirements.yml` imaju najmanje verzije koje odgovaraju Ansible paketu iz Ubuntu 24.04. Gost u VM-ovima je uvijek Ubuntu 24.04 iz zlatne slike, bez obzira na host.

**Ako nešto ne radi:**

| Simptom | Uzrok | Rješenje |
|---|---|---|
| `make check`: `/dev/kvm` ili libvirt | korisnik nije u grupama `kvm`/`libvirt`, ili nema ugniježđene virtualizacije | `sudo usermod -aG kvm,libvirt $USER`, pa ponovna prijava (WSL: `wsl --shutdown`) |
| Ansible ignoriše `ansible.cfg` | repozitorij je na `/mnt/c/...` | klonirati u `~/` |
| `Timed out waiting for become ... password prompt` | `sudo-rs` (Ubuntu 25.10+) | već riješeno (`group_vars/hypervisor.yml` koristi `sudo.ws` ako postoji) |
| `Permission denied` na disku VM-a | AppArmor nad libvirt slikama | `security_driver = "none"` u `/etc/libvirt/qemu.conf`, `sudo systemctl restart libvirtd` (napomena iz bilješki sedmice 2) |
| `corrupted-image: EOF` u Terraformu | prolazna greška libvirt providera 0.8 | `make infra` je ponavlja automatski; ručno: pokrenuti ponovo |
| `BADTIME` pri `make dns` | sat VM-a ne odgovara satu hosta | sat dolazi od hipervizora (`chrony` + `ptp_kvm`); `make test-vm` pokazuje razliku |
| test izolacije: dozvoljeni tokovi su blokirani | Docker na hostu postavio iptables `FORWARD` policy na `DROP`, a libvirt koristi nftables backend | `sudo iptables -S FORWARD`; rješenje je da Docker ne mijenja forward politiku (`"ip-forward-no-drop": true` u `/etc/docker/daemon.json`, Docker 28+) |

### Podizanje, test, uklanjanje

```bash
git clone <ovaj repozitorij> ~/ruo-troslojna && cd ~/ruo-troslojna
```

```bash
make setup      # jednom: alati, grupe, libvirt pool, kolekcije (samo ono što nedostaje)
make check      # svi alati, Docker, /dev/kvm, libvirt, kolekcije
make all        # od praznog sistema do aplikacije koja radi (traži sudo lozinku hosta jednom)
make test       # svi testovi sa sažetkom (traži sudo: promet iz namespace-a klijenta)
make destroy    # uklanja sve što je projekat kreirao i provjerava da ništa nije ostalo
```

**Aplikacija u pregledniku.** Aplikacija na VM-ovima je dostupna samo iz „interneta" projekta (namespace `ruo-klijent`), a preglednik nije u njemu. `make open` zato pokreće tunel: `socat` na hostu prima vezu na `localhost:8081` i svaku prosljeđuje **iz namespace-a klijenta** na `www.ruo.internal:80`. Zahtjev prolazi kroz isti vatrozid kao korisnik s interneta (samo do frontenda), pa se politika izolacije ne mijenja. WSL2 prosljeđuje `localhost` u Windows, pa adresa radi i u pregledniku na Windowsu.

```bash
make open       # http://localhost:8081 (traži sudo)
make close      # gasi tunel
```

`make all` izvršava redom `check` → `secrets` → `image` → `infra` → `config` → `dns` → `deploy`. Isti tok bez Makefilea, direktnim naredbama:

| Korak | Naredba |
|---|---|
| tajne | `bash scripts/secrets.sh` |
| slika | `packer init packer && packer build -var image_tag=<hash> -var output_dir=build/image-<hash> packer` |
| VM-ovi | `terraform -chdir=terraform/vm init && terraform -chdir=terraform/vm apply` |
| konfiguracija | `cd ansible && ansible-playbook config.yml -K` |
| DNS zapisi | `bash scripts/tf-dns.sh init && bash scripts/tf-dns.sh apply` (TSIG iz vaulta) |
| isporuka | `bash scripts/build-images.sh && cd ansible && ansible-playbook deploy.yml` |

**Trajanje** (izmjereno, slika u kešu): `make all` od praznog sistema **1 min 11 s**. Prva izgradnja zlatne slike traje dodatnih 5–8 min.

**Šta `make destroy` uklanja** (izlaz s izmjerenog pokretanja):

```text
== 1/4 DNS zapisi: dok DNS server još radi
Destroy complete! Resources: 12 destroyed.
== 2/4 ruter i namespace klijenta na hostu
localhost : ok=4  changed=2  unreachable=0  failed=0
== 3/4 VM-ovi, diskovi i mreže
Destroy complete! Resources: 25 destroyed.
== 4/4 generisane datoteke, stanje i tajne
== provjera: ništa od projekta ne smije ostati
  VM-ovi:  0
  mreže:   0
  diskovi: 0
```

Zlatna slika i arhive kontejnerskih slika namjerno ostaju kao keš izgradnje (artefakti, ne infrastruktura). Oznaka im je hash koda, pa se ponovo grade čim se kod promijeni. Sve briše `make distclean`.

### Izmjene kroz kod (primjeri za odbranu)

| Izmjena | Gdje | Primjena |
|---|---|---|
| novi DNS zapis (alias) | `terraform/dns/variables.tf` → `aliasi`, npr. `api = "backend"` | `make dns` → `Plan: 1 to add` |
| round-robin za frontend | `var.servisi`: `frontend = ["web1", "web2"]` (+ `web2` u `var.vms`) | `make infra config dns deploy` |
| memorija VM-a | `terraform/vm/variables.tf` → `vms.app1.memory_mb` | `make infra` (plan pokazuje izmjenu) |
| nova dozvola u vatrozidu | `mreza_politika` (jedan red) | `make config`: ruter i VM-ovi dobijaju isto pravilo |

### Lokalni razvoj (bez VM-ova)

`app/compose.dev.yaml` pokreće sva tri sloja na jednom računaru. Segmenti su tu Docker mreže, a `app` i `db` su `internal`.

```bash
make dev-up && make dev-test && make dev-persist      # http://localhost:8080
```

## 5. DNS zona i zapisi kao kod

`terraform/dns` upravlja zapisima kroz RFC 2136 (DNS UPDATE) potpisan TSIG ključem (AO-8). Adrese čita iz outputa `terraform/vm` (`terraform_remote_state`), a TSIG tajne dobija iz vaulta kroz `TF_VAR_*` (`scripts/tf-dns.sh`).

| Zapis | Vlasnik |
|---|---|
| SOA, NS, glue `ns1` | Ansible (rola `bind`), samo pri nastanku zone |
| `frontend`, `backend`, `db` (servisna imena koja koristi aplikacija) | Terraform, ključ `tf-ruo` |
| `web1`, `app1`, `db1`, `www` (CNAME → frontend), TXT `managed-by=terraform` | Terraform, ključ `tf-ruo` |
| PTR za sve VM-ove (`20.10.in-addr.arpa`) | Terraform, ključ `tf-ptr` |

Prava ključeva su najmanja potrebna. `tf-ruo` smije samo zonu `ruo.internal` i samo A/AAAA/CNAME/TXT/SRV (ne NS ni SOA). `tf-ptr` smije samo PTR u reverznoj zoni. Server je samo autoritativan (`recursion no`), a AXFR je dozvoljen samo uz ključ.

## 6. Drift

`make drift-dns` (`scripts/drift-dns.sh`) mijenja zapise koje posjeduje Terraform **mimo koda**, alatom `nsupdate`, isto kao s5/p2:

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

Ograničenje: Terraform vidi samo zapise koje je sam napravio. Ručno dodan zapis koji nije u kodu plan ne prijavljuje. Zato zona ima jednog vlasnika-alata, a pregled cijele zone ide preko `dig AXFR` uz ključ.

## 7. Idempotentnost

Drugi `make all` odmah nakon prvog (izlaz s izmjerenog pokretanja): Terraform ne mijenja ništa, a Ansible javlja `changed=0` na svim hostovima, uključujući i host (ruter).

```text
terraform/vm:   No changes. Your infrastructure matches the configuration.
                Apply complete! Resources: 0 added, 0 changed, 0 destroyed.

config.yml:     PLAY RECAP
                app1       : ok=9    changed=0    unreachable=0    failed=0    skipped=1
                db1        : ok=9    changed=0    unreachable=0    failed=0    skipped=1
                localhost  : ok=6    changed=0    unreachable=0    failed=0    skipped=1
                ns1        : ok=13   changed=0    unreachable=0    failed=0    skipped=1
                web1       : ok=9    changed=0    unreachable=0    failed=0    skipped=1

terraform/dns:  No changes. Your infrastructure matches the configuration.

deploy.yml:     PLAY RECAP
                app1       : ok=8    changed=0    unreachable=0    failed=0    skipped=4
                db1        : ok=12   changed=0    unreachable=0    failed=0    skipped=0
                web1       : ok=7    changed=0    unreachable=0    failed=0    skipped=5
```

Kako se to postiže:
- moduli opisuju stanje, a šabloni imaju `validate` i handlere;
- `command` zadaci imaju `changed_when`;
- početna zona se piše samo ako ne postoji (`force: false`);
- slike se prenose i učitavaju samo kad se promijene;
- Packer slika se gradi samo za novi hash koda.

Rola `router` i rola `firewall` provjeravaju i **stanje jezgre**, ne samo datoteku. Kad WSL restartuje i pravila nestanu, prvo izvršavanje ih vrati (`changed`), a drugo je ponovo `changed=0`.

## 8. Izlaz testova

`make test` (`tests/run-all.sh`) pokreće sve testove i ispisuje sažetak. Izlaz s izmjerenog pokretanja, skraćen na ključne redove:

```text
######## AO-3/AO-4  VM-ovi: plan bez promjena, cloud-init, SSH, sat
  ok: terraform/vm: plan bez promjena (exit 0)
-- app1 (10.20.2.10)                      [isto za db1, ns1, web1]
  ok: prijava ključem uz provjeru ključa servera
  ok: hostname je app1
  ok: cloud-init: done
  ok: adresa je iz adresnog plana
  ok: sat sinhronizovan s hostom (razlika 0s, izvor PHC/ptp_kvm)
  ok: prijava lozinkom odbijena (sshd nudi samo publickey)

######## AO-6       izolacija: matrica povezivosti
  klijent  -> web1     :80    dozvoljeno  (očekivano: dozvoljeno) ok      internet -> frontend: jedini ulaz izvana
  klijent  -> app1     :8000  blokirano   (očekivano: blokirano ) ok      internet -> backend
  klijent  -> db1      :5432  blokirano   (očekivano: blokirano ) ok      internet -> baza
  web1     -> app1     :8000  dozvoljeno  (očekivano: dozvoljeno) ok      frontend -> backend
  web1     -> db1      :5432  blokirano   (očekivano: blokirano ) ok      frontend -> baza: PRESKAKANJE SLOJA (ključni test)
  app1     -> db1      :5432  dozvoljeno  (očekivano: dozvoljeno) ok      backend -> baza
  app1     -> web1     :80    blokirano   (očekivano: blokirano ) ok      obrnuti smjer: backend -> frontend
  db1      -> app1     :8000  blokirano   (očekivano: blokirano ) ok      obrnuti smjer: baza -> backend
  web1     -> app1     :22    blokirano   (očekivano: blokirano ) ok      SSH između VM-ova
  db1      -> klijent  :9000  blokirano   (očekivano: blokirano ) ok      baza -> internet (nema izlaza)
  web1     -> klijent  :9000  blokirano   (očekivano: blokirano ) ok      frontend -> internet (nema izlaza)
  host     -> db1      :22    dozvoljeno  (očekivano: dozvoljeno) ok      admin (host) -> SSH
  host     -> db1      :5432  blokirano   (očekivano: blokirano ) ok      admin (host) -> baza: i host vidi samo SSH
  frontend -> db1      :5432  blokirano   (očekivano: blokirano ) ok      iz kontejnera frontenda
  ok: klijent razrješava imena preko ns1

######## AO-7/AO-8  DNS: zapisi, server, prava TSIG ključeva, plan
  ok: frontend.ruo.internal -> 10.20.1.10 (web1)
  ok: backend.ruo.internal -> 10.20.2.10 (app1)
  ok: db.ruo.internal -> 10.20.3.10 (db1)
  ok: PTR 10.20.2.10 -> app1.ruo.internal.     [i za sve ostale VM-ove]
  ok: www.ruo.internal je CNAME na frontend
  ok: odgovor je autoritativan (zastavica aa)
  ok: nepostojeće ime: NXDOMAIN
  ok: tuđa domena: REFUSED (nije rekurzivni server)
  ok: AXFR bez ključa: odbijen
  ok: AXFR s ključem tf-ruo: dozvoljen (13 zapisa)
  ok: tf-ruo ne smije u reverznu zonu
  ok: tf-ruo ne smije mijenjati NS (delegaciju)
  ok: tf-ptr ne smije u zonu projekta
  ok: tf-ptr ne smije A zapis ni u svojoj zoni
  ok: web1: backend -> 10.20.2.10
  ok: app1: db -> 10.20.3.10
  ok: terraform/dns: plan bez promjena (exit 0)

######## AO-7       nema IP literala u kodu
  ok: nema IP literala izvan adresnog plana

######## AO-1       aplikacija iz interneta (www.ruo.internal)
  ok: frontend živ (/healthz)
  ok: backend spreman i vidi bazu (/api/readyz)
  ok: upis bilješke (POST /api/notes -> 201)
  ok: upisana bilješka se čita iz baze
  ok: prazna bilješka se odbija (422)
  odgovorio backend: "served_by":"app1"

######## AO-10      perzistencija podataka baze
  ok: upis (HTTP 201)
  ok: kontejner je nov (ID 14df338e2680 -> d65d1e17308a)     [docker compose up --force-recreate]
  ok: podatak je i dalje tu
  ok: podatak je i dalje tu                                   [docker rm -f, pa ponovo]
     /dev/vdb /srv/pgdata ext4
     /srv/pgdata -> /var/lib/postgresql/data

######## AO-9       tajne nisu u Gitu (ni u historiji)
  ok: nijedna datoteka s tajnom ili stanjem nije praćena sada
  ok: nijedna takva datoteka nije ni u historiji (12 commitova)
  ok: vault.yml je šifrovan (AES256)
  ok: vrijednost vault_db_password se ne pojavljuje ni u jednom commitu
  ok: vrijednost vault_tsig_tf_ruo se ne pojavljuje ni u jednom commitu
  ok: vrijednost vault_tsig_tf_ptr se ne pojavljuje ni u jednom commitu
  ok: nijedan privatni ključ (PEM/OpenSSH) u historiji

======== SAŽETAK ========
  ok        AO-3/AO-4  VM-ovi: plan bez promjena, cloud-init, SSH, sat
  ok        AO-6       izolacija: matrica povezivosti
  ok        AO-7/AO-8  DNS: zapisi, server, prava TSIG ključeva, plan
  ok        AO-7       nema IP literala u kodu
  ok        AO-1       aplikacija iz interneta (www.ruo.internal)
  ok        AO-10      perzistencija podataka baze
  ok        AO-9       tajne nisu u Gitu (ni u historiji)
Svi testovi su prošli.
```

Pojedinačno: `make test-vm`, `test-isolation`, `test-dns`, `test-ip`, `test-app`, `test-persist`, `test-secrets`.

### Matrica sljedivosti

| AO | Implementacija | Dokaz |
|---|---|---|
| AO-1 | `app/*/Dockerfile`, `app/compose.yaml` (profili po sloju), nginx → backend → baza | `tests/app.sh` |
| AO-2 | `Makefile` (`all`, `destroy`) | ciklus destroy → all → test → all |
| AO-3 | `terraform/vm` (varijable s validacijom, outputi, state u `.gitignore`) | `tests/vm.sh` (plan exit 0) |
| AO-4 | `cloud-init/user-data.tftpl` (`ssh_pwauth: false`, `lock_passwd: true`) | `tests/vm.sh` (ključ da, lozinka ne) |
| AO-5 | `ansible/roles/*` | drugi run: `changed=0` (odjeljak 7) |
| AO-6 | libvirt route mreže, role `router` i `firewall`, `network_mode: host` | `tests/isolation.sh` |
| AO-7 | rola `bind`, imena u compose/nginx/backend | `tests/dns.sh`, `tests/no-ip-literals.sh` |
| AO-8 | `terraform/dns`, `update-policy` po ključu | `tests/dns.sh`, `make drift-dns` |
| AO-9 | `make secrets`, ansible-vault, `*_FILE`, `.gitignore` | `tests/secrets.sh` |
| AO-10 | zaseban libvirt disk `vdb` → `/srv/pgdata` | `tests/persistence.sh` |

## 9. Tajne

| Tajna | Nastaje | Čuva se | Na VM-u |
|---|---|---|---|
| lozinka baze | `make secrets` (`openssl rand -hex 24`) | `vault.yml` (AES256) | `/etc/ruo/secrets/db_password`, 0400, vlasnik je proces u kontejneru; čita se preko `*_PASSWORD_FILE` |
| TSIG `tf-ruo`, `tf-ptr` | `make secrets` (`openssl rand -base64 32`) | `vault.yml` | ns1: `/etc/bind/ruo-keys.conf`, 0640 root:bind; Terraform: `TF_VAR_*` u memoriji |
| lozinka za vault | `make secrets` | `.vault_pass`, 0600 | — |
| SSH ključ administratora | `make ssh-key` | `~/.ssh/ruo_ed25519` (van repozitorija) | javni dio preko cloud-inita |
| ključevi SSH servera | Terraform (`tls_private_key`) | Terraform state (nije u Gitu) | cloud-init `ssh_keys` |

U Gitu je samo `ansible/inventory/group_vars/all/vault.yml.example`. `make destroy` briše tajne zajedno s okruženjem.

## 10. Struktura repozitorija

```
app/            frontend/, backend/, db/init/; compose.yaml (VM-ovi), compose.dev.yaml (lokalno)
packer/         zlatna slika VM-ova: ruo-base.pkr.hcl, seed/, scripts/provision.sh
terraform/vm/   mreže, diskovi, VM-ovi, ključevi servera, generisani inventory (AO-3)
terraform/dns/  DNS zapisi: servisi, hostovi, CNAME, TXT, PTR (AO-8)
cloud-init/     user-data, network-config, meta-data šabloni (AO-4)
ansible/        config.yml, deploy.yml, teardown.yml; role: router, common, firewall, docker, bind, app
scripts/        setup.sh, secrets.sh, vault-get.sh, tf-dns.sh, build-images.sh, drift-dns.sh, nsupdate-key.sh, tf-retry.sh
tests/          run-all.sh (make test), vm.sh, isolation.sh, dns.sh, no-ip-literals.sh, app.sh, persistence.sh, secrets.sh
docs/adr/       ADR-ovi DO-1 … DO-9
Makefile        ulaz u sve korake (make help)
```

**Odstupanja od preporučene strukture** (isječak 2 zadatka):
- `packer/` je dodat jer je bazna slika vlastita Packer slika (DO-4);
- `scripts/` sadrži pomoćne skripte koje koriste Makefile i testovi (priprema hosta, tajne, TSIG za Terraform, drift);
- `docs/adr/` sadrži ADR-ove, iz kojih nastaje PDF;
- `app/db/` sadrži šemu baze, jer baza koristi zvaničnu sliku bez vlastitog Dockerfilea.

**Preuzeto iz repozitorija predmeta i prilagođeno:**

| Primjer | Šta je preuzeto | Prilagođeno |
|---|---|---|
| s2/p3 | Terraform + libvirt, qcow2 potomak bazne slike | `for_each` nad mapom, route mreže, statičke adrese, `replace_triggered_by` |
| s2/p2 | cloud-init korisnik s ključem | ključ servera iz Terraforma, netplan, sshd drop-in |
| s2/p4 | Packer slika, `cloud-init clean`, `passwd -l` | nasumična build lozinka, chrony/ptp_kvm, oznaka po hashu |
| s3/p2 | role, Vault, `vault_` prefiks | vault generisan pri prvom pokretanju |
| s3/p3 | Terraform generiše inventory, čekanje na cloud-init | YAML inventory + `known_hosts` umjesto isključene provjere ključa |
| s3/p4 | Dockerfile (multi-stage, ne-root, healthcheck), compose | digest, profili po sloju, mreža VM-a, tajne kao datoteke |
| s4/p2, s4/p3, s4/p4 | ruter, nftables default deny, politika kao podaci, matrica povezivosti | pravi VM-ovi, ograničenje na projektna sučelja, isti podaci za ruter i VM-ove |
| s5/p1, s5/p2 | BIND, RFC 2136 + TSIG, `update-policy`, drift | dva ključa s ograničenim tipovima, reverzna zona, test prava ključeva |

## 11. Poznata ograničenja

- **Jedan DNS server** (nema sekundarnog): svjesno prihvaćen SPOF u labu (DO-8).
- **Jedna instanca po sloju.** Round-robin je pripremljen (`var.servisi`), ali nije aktivan.
- **Frontend radi na HTTP-u, bez TLS-a.** U produkciji bi certifikat izdavao ACME, i to DNS-01 izazovom kroz isti RFC 2136 mehanizam.
- **Povremena greška libvirt providera 0.8:** odmah nakon kreiranja cloud-init ISO-a provider ga ponekad ne uspije pročitati (`corrupted-image: EOF`). ISO je ispravan (provjereno `isoinfo`), a sljedeće izvršavanje prolazi. `scripts/tf-retry.sh` ponavlja naredbu jednom, ali **samo za tu poruku**. Ako se obični `terraform plan` pokrene u prvoj minuti nakon `apply`, rijetko se može vidjeti ova greška; ponovno pokretanje je rješava.
- **Ubuntu 26.04 koristi `sudo-rs`**, koji ne radi s Ansible `become`. Na hostu se zato koristi klasični `sudo.ws` (`group_vars/hypervisor.yml`); sistemska postavka se ne mijenja.
- Kolekcija `ansible.posix` ispisuje upozorenja o zastarjelim internim API-jima. Upozorenja dolaze iz kolekcije i ne utiču na rezultat.
