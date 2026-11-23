# Zapisi dizajnerskih odluka (ADR)

Svaka dizajnerska odluka (DO) iz projektnog zadatka ima jedan zapis, prema obrascu iz zadatka (isječak 1): Status, Kontekst, Razmotrene opcije, Odluka, Obrazloženje i posljedice. Odluka se ne briše kad se promijeni: novi ADR je zamjenjuje, a stari dobija status „zamijenjeno".

| DO | Pitanje | Izabrana opcija |
|---|---|---|
| [DO-1](#do-1-aplikacija-i-tehnologije-slojeva) | Aplikacija i tehnologije | vlastita aplikacija „Trezor" (povjerljive bilješke): nginx 1.27.5 · FastAPI (Python 3.12) · PostgreSQL 17.12 |
| [DO-2](#do-2-broj-virtuelnih-mašina-i-raspored-komponenti) | Broj VM-ova i raspored | 4 VM-a (ns1, web1, app1, db1), libvirt `route` mreže, host je ruter s default deny, kontejneri na mreži VM-a |
| [DO-3](#do-3-plan-adresiranja) | Plan adresiranja | jedan literal `10.20.0.0/16`, segmenti `/24` (`cidrsubnet`), adrese `cidrhost`, statički preko netplana, bez DHCP-a |
| [DO-4](#do-4-bazna-slika-vm-a) | Bazna slika VM-a | vlastita Packer slika (Ubuntu 24.04 + Docker, nftables, BIND, chrony/ptp_kvm); cloud-init samo za instancu |
| [DO-5](#do-5-izgradnja-i-distribucija-slika-kontejnera) | Slike kontejnera | build jednom na kontrolnom čvoru, oznaka = hash koda, bazne slike po digestu, isporuka kao arhiva |
| [DO-6](#do-6-kako-ansible-dobija-adrese-vm-ova-koje-je-kreirao-terraform) | Adrese za Ansible | Terraform generiše inventory, adresni plan i `known_hosts` (ključevi servera iz Terraforma) |
| [DO-7](#do-7-organizacija-ansible-rola-i-varijabli) | Ansible role i varijable | role po funkciji (router, firewall, docker, bind, app); sva konfiguracija servera u rolama; politika mreže kao podaci |
| [DO-8](#do-8-dizajn-dns-zone) | DNS zona | `ruo.internal` + reverzna, jedan vlasnik po zapisu, TSIG ključ po zoni i tipu, TTL 300 s, bez sekundarnog |
| [DO-9](#do-9-upravljanje-tajnama) | Tajne | generisanje pri prvom pokretanju + `ansible-vault`; datoteke 0400 umjesto varijabli okruženja; test historije |

---

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

Opcija 3: vlastita aplikacija **„Trezor"** za povjerljive bilješke (npr. interne napomene tima koje ne smiju izaći van).

| Sloj | Tehnologija | Uloga |
|---|---|---|
| frontend | nginx 1.27.5 (zvanična slika), statični HTML/JS bez build koraka | jedini ulaz; poslužuje stranicu i prosljeđuje `/api/` na `backend.<zona>:8000` |
| backend | Python 3.12.16, FastAPI, psycopg 3 + connection pool | REST API: `GET/POST /api/notes`, `GET /api/healthz` (liveness), `GET /api/readyz` (baza odgovara) |
| baza | PostgreSQL 17.12 (zvanična alpine slika) | tabela `notes`; šema iz `docker-entrypoint-initdb.d`, izvršava se samo nad praznim direktorijem podataka |

## Obrazloženje i posljedice

Šta se dobija:
- **Povjerljivi podaci daju smisao zaštiti.** Baza čuva sadržaj koji ne smije procuriti, pa je cilj infrastrukture da napadač koji preuzme izloženi frontend nema put do baze, i da podaci ne mogu izaći van. Iz tog cilja dolaze baza u vlastitom segmentu bez objavljenog porta i bez izlaza na internet (DO-2), zaštita na tri nivoa i tajne kao šifrovane datoteke (DO-9).
- **Kod koji se može objasniti red po red.** Backend ima oko 140 redova, frontend jednu stranicu.
- **Smisleno dokazive AO.** Upis i čitanje bilješke prolaze kroz sva tri sloja (AO-1). Podatak u PostgreSQL-u preživljava `docker compose up --force-recreate` i `docker rm -f` (AO-10).
- **Konfiguracija samo iz okruženja.** Adrese su DNS imena (`DB_HOST=db.ruo.internal`), a lozinka se čita iz datoteke (`DB_PASSWORD_FILE`), jer se varijable okruženja vide u `docker inspect`.
- **Odvojeni liveness i readiness** (obrazac iz s3/p4). Pad baze ne izaziva restart backenda. Pool provjerava vezu pri izdavanju, pa nakon ponovnog kreiranja kontejnera baze backend sam uspostavlja nove veze.
- **nginx razrješava ime backenda u toku rada** (`resolver` iz `/etc/resolv.conf`, ime u varijabli). Promjena DNS zapisa važi bez restarta frontenda.
- **PostgreSQL** je relacijska baza s transakcijama i gradivo predmeta; Python je jezik primjera s vježbi. FastAPI daje validaciju ulaza (prazna bilješka: 422) i OpenAPI dokumentaciju.

Šta se gubi:
- Aplikacija nije „impresivna", ali se ona i ne boduje. Gotova open-source aplikacija bi donijela dodatne servise (keš, redovi poruka, migracije) koji bi zamutili troslojnu strukturu i povećali gradivo za odbranu.
- PostgreSQL 18 nije izabran jer zvanična slika verzije 18 mijenja podrazumijevani `PGDATA` i mjesto volumena. Verzija 17 zadržava klasičan `/var/lib/postgresql/data`.

---

# DO-2: Broj virtuelnih mašina i raspored komponenti

Status: prihvaćeno

## Kontekst

Aplikacija ima tri sloja, svaki u svom kontejneru (AO-1). Slojevi moraju biti mrežno izolovani (AO-6): svaki u svom segmentu s vlastitom podmrežom, izvana je dostupan samo frontend, frontend nema mrežni pristup bazi, a baza nema objavljen port. Projekat ima vlastiti autoritativni DNS (AO-7). VM-ove kreira Terraform (AO-3).

Treba odlučiti koliko VM-ova sistem ima i kako su komponente raspoređene, tako da izolacija bude stvarna i dokaziva testom. Okruženje je WSL2 na Windows 11 s ugniježđenom KVM virtualizacijom i 32 GB RAM-a.

## Razmotrene opcije

1. **Varijanta A:** jedna VM, segmenti kao Docker mreže s fiksnim podmrežama, kontejner samo na mrežama koje mu trebaju.
2. **Varijanta B:** VM po segmentu na libvirt mrežama u `route` modu, kontejneri u Docker bridge mreži s objavljenim portovima.
3. **Varijanta B s mrežom VM-a za kontejnere:** VM po segmentu, kontejneri u `network_mode: host`, Docker ne upravlja iptables-om, DNS na zasebnoj VM.
4. Varijanta B s ipvlan mrežom za kontejner baze (kontejner dobija vlastitu adresu u segmentu).

## Odluka

Opcija 3. Četiri VM-a:

| VM | Segment | Komponenta |
|---|---|---|
| ns1 | infra | autoritativni DNS (BIND) |
| web1 | web | frontend (kontejner) |
| app1 | app | backend (kontejner) |
| db1 | db | baza (kontejner) + zaseban disk za podatke |

Host (WSL) je ruter između segmenata i ima centralni vatrozid s pravilom „zabranjeno sve što nije nabrojano". Svaki VM ima i vlastiti vatrozid. Svaki kontejner koristi mrežu svog VM-a, a Docker daemon radi s `iptables: false`, `bridge: none` i `ip-forward: false`. „Internet" je mrežni namespace `ruo-klijent` spojen na host, pa njegov promet prolazi kroz ruter kao pravi promet izvana.

## Obrazloženje i posljedice

Šta se dobija:
- **Izolacija na nivou kernela.** Kompromitovan frontend ne dijeli kernel ni Docker daemon s bazom. U varijanti A sva tri sloja dijele oboje.
- **Segmentacija kao u oblaku.** Segment odgovara podmreži (subnet), host tabeli usmjeravanja, a pravila na hostu i VM-ovima ulozi network ACL-a i security grupe. To je primjena s2/p3 + s4/p2 + s4/p3 na pravim VM-ovima.
- **Dva nivoa zaštite.** Promet mora proći i ruter i vatrozid ciljnog VM-a. Za bazu postoji i treći nivo, `pg_hba.conf`.
- **Zašto mreža VM-a za kontejnere.** Docker objavljeni port pravi DNAT u `prerouting`, pa promet ide kroz `forward` lanac VM-a i zaobilazi njegov `input` vatrozid (poznata zamka Docker + ufw/nftables). Osim toga, objavljeni port baze bi doslovno prekršio AO-6. U host modu nema `ports:`, nema DNAT-a, pa je nftables VM-a jedini zakon. VM je jedinica mrežne izolacije, a kontejner daje pakovanje, verziju i izolaciju procesa.
- **DNS u zasebnom segmentu.** DNS koriste svi slojevi. Da je u segmentu nekog sloja, pravila bi morala otvoriti pristup tom sloju. U zasebnom segmentu dovoljna je jedna dozvola (port 53) prema servisu koji nije dio aplikacije.
- **Bez izlaza na internet.** Paketi su u zlatnoj slici (DO-4), a slike kontejnera stižu s kontrolnog čvora (DO-5), pa nijedan segment nema put prema van. Kompromitovana baza ne može iznijeti podatke.
- **Dokazano testom.** `tests/isolation.sh` ima 14 provjera, uključujući frontend → baza iz samog kontejnera frontenda; sve se poklapaju s politikom.

Šta se gubi:
- **Resursi:** oko 4,5 GB RAM-a (varijanta A: 1–2 GB).
- **Više koda:** ruter na hostu, vatrozid na svakom VM-u, više Terraform resursa. Podizanje od nule traje oko 1 min 11 s (sa slikom u kešu).
- **Zavisnost od KVM-a:** u WSL2 to je ugniježđena virtualizacija.
- **Host je dijeljen** (libvirt, Docker, labovi predmeta). Zato tabela rutera primjenjuje default deny samo na promet projektnih sučelja (`iifname/oifname @projekat_if`), a tuđi promet ne dira.
- **Kontejner dijeli mrežni stack s VM-om.** To je prihvatljivo jer je na VM-u samo jedan kontejner, pa nema sukoba portova.
- **Ipvlan (opcija 4)** bi dao kontejneru vlastitu adresu, ali host tada ne može razgovarati s kontejnerom preko istog sučelja, a otklanjanje grešaka je teže. Ništa ne donosi što host mod već ne daje.

---

# DO-3: Plan adresiranja

Status: prihvaćeno

## Kontekst

AO-6 traži vlastitu podmrežu za svaki segment. AO-7 zabranjuje da komponente koriste IP adrese i provjerava se pretragom koda za IP adrese. AO-3 kaže da su adrese outputi Terraforma. Na računaru već postoje mreže s kojima se adrese ne smiju preklapati: libvirt `default` (192.168.122.0/24), Docker (172.17.0.0/16), WSL (172.x) i labovi predmeta (10.40.0.0/16, 10.50.0.0/24).

## Razmotrene opcije

1. Dinamičke adrese preko DHCP-a (libvirt dnsmasq).
2. DHCP s rezervacijama po MAC adresi.
3. Statičke adrese kroz cloud-init `network-config` (netplan), bez DHCP-a.
4. IPv6 ili dual-stack.

Za zapis plana: adrese ručno upisane u svaku datoteku, ili izvedene iz jednog podatka.

## Odluka

Opcija 3. Sve adrese se izvode iz **jednog literala**, `project_cidr = "10.20.0.0/16"` u `terraform/vm/variables.tf`:
- podmreže: `cidrsubnet(project_cidr, 8, n)`;
- adrese: `cidrhost(podmreža, hostnum)`;
- gateway je `cidrhost(podmreža, 1)`, tj. adresa hosta na bridgeu segmenta.

| Segment | n | Podmreža | Gateway | VM | Adresa |
|---|---|---|---|---|---|
| infra | 0 | 10.20.0.0/24 | 10.20.0.1 | ns1 | 10.20.0.53 |
| web | 1 | 10.20.1.0/24 | 10.20.1.1 | web1 | 10.20.1.10 |
| app | 2 | 10.20.2.0/24 | 10.20.2.1 | app1 | 10.20.2.10 |
| db | 3 | 10.20.3.0/24 | 10.20.3.1 | db1 | 10.20.3.10 |
| klijent | 255 | 10.20.255.0/30 | 10.20.255.1 | namespace | 10.20.255.2 |

Konvencija: `.1` je gateway (host), `.2–.9` su rezerva, `.10+` su hostovi (validacija u Terraformu to provodi), a DNS je `.53`. Na projektnim mrežama DHCP i dnsmasq su isključeni.

## Obrazloženje i posljedice

Šta se dobija:
- **Jedan izvor istine.** Inventory, vatrozid, `pg_hba.conf`, zone i DNS zapisi dobijaju adrese iz Terraform outputa. `tests/no-ip-literals.sh` pretražuje kod i dozvoljava samo `project_cidr`. Promjena cijelog plana je jedna linija.
- **Determinističke adrese.** Nema DHCP zakupa ni dnsmasq-a na projektnim mrežama (manja površina napada), a netplan je trajna konfiguracija mreže iz s4/p1.
- **/24 po segmentu** je čitljivo, poravnato na oktet (pravila vatrozida su jasna) i ostavlja mjesto za horizontalno skaliranje (npr. `web2` na `.11` uz round-robin, DO-8). **/16 supernet** dozvoljava sumarizaciju (`allow-query { 10.20.0.0/16; }` u BIND-u).
- **Bez sudara** s mrežama na računaru i u labovima predmeta.

Šta se gubi:
- Bez DHCP-a, `wait_for_lease` ne potvrđuje adresu. Kompenzacija: `tests/vm.sh` na svakom VM-u poredi stvarnu adresu (`ip -br addr`) s planom.
- **Resolver VM-a je IP adresa DNS servera.** To je jedino mjesto gdje komponenta vidi IP, i neizbježno je: DNS se ne može naći preko DNS-a (bootstrap). Adresa ne stoji u kodu, nego je izvedena u Terraformu.
- IPv6 nije implementiran (obim projekta), ali su nftables tabele `inet`, spremne i za IPv6.

---

# DO-4: Bazna slika VM-a

Status: prihvaćeno

## Kontekst

Početnu konfiguraciju VM-a radi cloud-init: korisnik za upravljanje sa SSH ključem i onemogućena prijava lozinkom (AO-4). Segmenti nemaju izlaz na internet (DO-2), pa VM pri pokretanju ne može instalirati pakete. Okruženje se mora moći podići od nule bez ručnih koraka (AO-2), brzo i ponovljivo.

## Razmotrene opcije

1. Javna Ubuntu cloud slika + cloud-init koji instalira pakete (`packages:`, kao s2/p3).
2. Javna cloud slika + Ansible koji instalira pakete.
3. Vlastita slika izgrađena Packerom (s2/p4) s preinstaliranim paketima + cloud-init samo za ono što je specifično za instancu.
4. Zasebna Packer slika za svaku ulogu (DNS, web, app, db).

## Odluka

Opcija 3: jedna slika za sve VM-ove, `build/image-<hash>/ruo-base.qcow2`.

- **Polazište:** Ubuntu 24.04 cloud slika, provjerena preko `SHA256SUMS`.
- **Sadržaj:** Docker Engine i Compose plugin (`docker.io`, `docker-compose-v2` iz Ubuntu arhive), `python3-docker`, `nftables`, `bind9`, `qemu-guest-agent` i `chrony` sa `linux-modules-extra`.
- **Servisi nisu uključeni:** Docker i BIND su u slici isključeni, a uključuje ih Ansible prema ulozi VM-a.
- **Sat VM-a:** `chrony` uzima vrijeme od hipervizora (`refclock PHC /dev/ptp_kvm`), bez mreže.
- **Čišćenje na kraju builda:** `passwd -l ubuntu`, `cloud-init clean --logs --seed`, prazan `machine-id`, brisanje ključeva SSH servera.
- **Lozinka za build** je nasumična pri svakoj izgradnji (`uuidv4()`, `sensitive`), umjesto `packer` upisanog u kod kao u s2/p4.
- **Oznaka slike** je hash sadržaja mape `packer/`. `make image` gradi samo ako slika za tu oznaku ne postoji.

cloud-init (`terraform/vm/cloud-init/*.tftpl`) radi samo ono što je specifično za instancu:
- hostname, korisnik `ops` sa SSH ključem i `lock_passwd: true`;
- `ssh_pwauth: false`, plus drop-in za sshd koji isključuje lozinke kao drugu liniju odbrane;
- ključ SSH servera koji je napravio Terraform (DO-6);
- statička mreža i resolver (DO-3).

## Obrazloženje i posljedice

Šta se dobija:
- **Segmenti bez izlaza na internet**, što je sigurnosni dobitak, posebno za bazu.
- **Brzo i determinističko podizanje.** Isti paketi na svakom VM-u, bez zavisnosti od dostupnosti mirrora u trenutku podizanja.
- **Nepromjenjiva infrastruktura.** Nova slika znači nove VM-ove (`replace_triggered_by` u Terraformu), a ne krpljenje postojećih. Disk s podacima baze nije u toj listi, pa preživljava zamjenu VM-a.
- **Jedna slika za sve uloge:** VM-ovi su međusobno zamjenjivi („stoka"), a ulogu određuje Ansible.
- **Sat bez mreže.** VM-ovi bez izlaza ne mogu koristiti javne NTP servere, a WSL ih pauzira, pa sat zaostaje. U projektu je izmjereno 24 minute, i TSIG (AO-8) je zato odbijao izmjene DNS-a (`BADTIME`). `ptp_kvm` daje sat hipervizora direktno kroz hipervizor; `tests/vm.sh` provjerava razliku od najviše 2 s.

Šta se gubi:
- **Vrijeme izgradnje:** 5–8 minuta, jednom po izmjeni koda slike. `make destroy` namjerno ne briše sliku (artefakt kao keš), a `make distclean` je briše.
- **Prostor:** oko 1 GB po slici. Stare slike se brišu automatski.
- **Zakrpe** zahtijevaju novu sliku i zamjenu VM-ova.
- **Packer je dodatni alat.** Modul `ptp_kvm` zahtijeva `linux-modules-extra` (+114 MB).
- **Zasebne slike po ulozi** (opcija 4) bi bile manje, ali bi broj artefakata koje treba graditi i pratiti bio četiri puta veći.

---

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

---

# DO-6: Kako Ansible dobija adrese VM-ova koje je kreirao Terraform

Status: prihvaćeno

## Kontekst

VM-ove kreira Terraform (AO-3), a konfiguriše ih Ansible (AO-5). Ansible mora znati koje mašine postoje, na kojim adresama i u kojim su segmentima, bez ručnog prepisivanja (AO-2). Dodatni zahtjev: Ansible ne smije isključiti provjeru ključa SSH servera, jer je `ANSIBLE_HOST_KEY_CHECKING=False` iz s3/p3 prihvatljivo samo u labu.

## Razmotrene opcije

1. Ručno napisan inventory.
2. Terraform generiše inventory kao `local_file` (s3/p3).
3. Skripta u Makefileu: `terraform output -json` → inventory.
4. Dinamički inventory: Terraform provider `ansible/ansible` + Ansible plugin `cloud.terraform.terraform_provider`.

## Odluka

Opcija 2, proširena (`terraform/vm/main.tf` i `locals.tf`). Iz istih podataka iz kojih pravi VM-ove, Terraform generiše tri datoteke:

| Datoteka | Sadržaj |
|---|---|
| `ansible/inventory/hosts.yml` | grupe `hypervisor` (localhost), `vms` → `infra`, `web`, `app`, `db`; po hostu `ansible_host` |
| `ansible/inventory/group_vars/all/generated.yml` | adresni plan (segmenti, gatewayi, adresa DNS-a, zona, klijent), korisnik i ključ za SSH |
| `ansible/known_hosts` | javni ključevi SSH servera svih VM-ova |

Ključeve SSH servera pravi Terraform (`tls_private_key`, ed25519), a cloud-init ih postavlja na VM (`ssh_keys`). Ansible radi sa `StrictHostKeyChecking=yes` i tim `known_hosts`.

## Obrazloženje i posljedice

Šta se dobija:
- **Jedan izvor istine.** Topologija je samo u Terraformu, pa promjena broja VM-ova automatski mijenja i inventory.
- **Čitljiv rezultat.** Generisani YAML se može pregledati, a `yamlencode` garantuje ispravan YAML.
- **Provjera identiteta od prvog spajanja.** Kontrolni čvor unaprijed zna ključ svakog servera, pa nema pitanja „yes/no", nema isključene provjere i nema ranjivosti na man-in-the-middle pri prvom spajanju.
- **Nema dodatnih zavisnosti.** Dinamički plugin bi tražio još jedan provider, kolekciju i čitanje Terraform statea iz Ansible-a, a za četiri statična hosta to je složenost bez koristi.

Šta se gubi:
- Generisane datoteke su izvedeni artefakti (u `.gitignore`) i postoje tek nakon `make infra`; `make config` provjerava da postoje.
- Privatni ključevi SSH servera su u Terraform stateu i u cloud-init ISO-u u libvirt poolu. To je prihvatljivo: state nije u Gitu (AO-3, AO-9), pool je čitljiv samo rootu, a pri svakom `make destroy` ključevi se brišu i prave novi.
- Za druge (ne-Terraform) izvore mašina ovaj pristup ne radi. U oblaku s mnogo mašina dinamički inventory je bolji izbor.

---

# DO-7: Organizacija Ansible rola i varijabli

Status: prihvaćeno

## Kontekst

Konfiguraciju servera radi Ansible, organizovan u role, a playbook je idempotentan (AO-5). Isti Docker i vatrozid trebaju na više VM-ova, ruter na hostu, a DNS server samo na ns1. Pravila vatrozida na ruteru i na VM-ovima moraju opisivati istu politiku. Tajne se ne smiju miješati s običnim varijablama (AO-9).

## Razmotrene opcije

1. Rola po komponenti (`frontend`, `backend`, `database`, `dns`), od kojih svaka sama instalira Docker i vatrozid.
2. Rola po funkciji + jedna parametrizovana rola za isporuku aplikacije.
3. Jedan veliki playbook bez rola.

Za varijable: sve u `group_vars`; sve u `defaults` rola; ili jasna podjela po prioritetu.

## Odluka

Opcija 2. **Sve što mijenja servere je u rolama**; playbookovi samo biraju hostove i redoslijed. Van rola je jedino čekanje da VM bude spreman (`pre_tasks`), koje na serveru ništa ne mijenja.

| Rola | Hostovi | Zadatak |
|---|---|---|
| `router` | hypervisor (host) | tabela `inet ruo3t`: default deny za projektna sučelja, namespace klijenta, `ip_forward` |
| `firewall` | svi VM-ovi | nftables `input` iz politike; `validate: nft -c`; provjera da su pravila učitana u jezgru |
| `docker` | web, app, db | `daemon.json` (bez iptables-a, bez bridgea), pa tek onda servis |
| `bind` | infra | BIND: opcije, zone, TSIG ključevi, početne zone (`force: false`) |
| `app` | web, app, db | disk za podatke, tajna, `pg_hba.conf`, slike, `docker compose --profile <sloj>` |

Playbookovi:
- `config.yml`: rola router; na svim VM-ovima `pre_tasks` (čekanje SSH-a i cloud-inita po obrascu s3/p3, činjenice) pa rola firewall; rola docker; rola bind;
- `deploy.yml`: rola app, redom baza → backend → frontend;
- `teardown.yml`: rola router, stanje „nema".

Varijable, od najnižeg prioriteta prema najvišem:
- `roles/*/defaults/main.yml`: sigurne generičke vrijednosti role (putanje, ime tabele, opcije Docker daemona);
- `group_vars/all/main.yml`: ono što važi za cijelo okruženje, uključujući portove i **mrežnu politiku kao podatke** (`mreza_politika`);
- `group_vars/all/generated.yml`: adresni plan iz Terraforma (DO-6);
- `group_vars/all/vault.yml`: samo `vault_*` vrijednosti, šifrovano; obične varijable upućuju na njih (`ruo_tsig`, `vault_db_password`), po dogovoru iz s3/p2;
- `group_vars/<segment>.yml`: specifičnosti segmenta (`app_profil`, UID vlasnika tajne, disk za podatke, dodatni admin ulaz za DNS);
- `group_vars/hypervisor.yml`: `ansible_become_exe`, klasični `sudo`, jer `sudo-rs` (podrazumijevan na Ubuntu 26.04) ne radi s Ansible `become`.

## Obrazloženje i posljedice

Šta se dobija:
- **Nema dupliranja.** Docker i vatrozid postoje jednom i primjenjuju se gdje trebaju.
- **Jasna granica.** Pet rola, svaka s jednom cjelinom; playbook se čita kao spisak „koja rola na kojim hostovima", a cijela konfiguracija servera je u rolama (AO-5).
- **Politika je na jednom mjestu.** Iz `mreza_politika` nastaju i pravila rutera i ulazna pravila VM-ova, pa se dva nivoa zaštite ne mogu razići. Nova dozvola je jedan red podataka (proširenje s4/p4).
- **Idempotentnost i konvergencija.** Šabloni s `validate` mijenjaju datoteku samo kad se sadržaj promijeni, a handleri reaguju samo na promjenu. Provjere stanja jezgre (pravila učitana?) vraćaju sistem u željeno stanje i nakon restarta WSL-a, a javljaju `changed` samo kad stvarno moraju nešto uraditi. Izmjereno: drugi `make all` daje `changed=0` na svih pet hostova.
- **Redoslijed isporuke prati zavisnosti**, a svaki sloj se čeka dok ne postane zdrav.

Šta se gubi:
- Rola `app` je generička, pa se ponašanje po hostu čita iz `group_vars`; to traži poznavanje prioriteta varijabli.
- Rola `router` traži sudo lozinku hosta (`-K`). Bez toga se mogu konfigurisati samo VM-ovi (`make config-vms`).
- `ansible.posix.sysctl` i `mount` ispisuju upozorenje o zastarjelim internim API-jima iz kolekcije. Upozorenje dolazi iz kolekcije, ne iz projekta, i ne utiče na rezultat.

---

# DO-8: Dizajn DNS zone

Status: prihvaćeno

## Kontekst

Projekat ima vlastitu autoritativnu DNS zonu (BIND), a komponente se međusobno adresiraju isključivo DNS imenima (AO-7). DNS zapisi servisa su Terraform resursi (provider `hashicorp/dns`, RFC 2136), a TSIG ključ smije mijenjati samo zonu projekta (AO-8). Na odbrani se traže `dig` upiti, `terraform plan` i demonstracija drifta.

## Razmotrene opcije

1. Ime zone: `ruo.lab` (kao na vježbama), `ruo.local`, `home.arpa`, `ruo.internal`.
2. Struktura: statička zona u Gitu + delegirana dinamička zona (s5/p1), ili dinamička zona s jasnim vlasnikom svakog zapisa.
3. Sekundarni server: da ili ne.
4. PTR zapisi: da ili ne; jednim ključem ili posebnim.

## Odluka

- **Zona `ruo.internal`**, reverzna zona `20.10.in-addr.arpa`. Server je ns1 (BIND 9.18), samo primarni.
- **Vlasnik svakog zapisa:**

| Zapis | Vlasnik |
|---|---|
| SOA, NS, glue `ns1` | Ansible (rola `bind`), samo pri nastanku zone (`force: false`) |
| `frontend`, `backend`, `db` (servisna imena), `web1`, `app1`, `db1` (hostovi), `www` CNAME → `frontend`, TXT `managed-by=terraform` | Terraform, ključ `tf-ruo` |
| PTR za sve VM-ove | Terraform, ključ `tf-ptr` |

- **Prava ključeva (`update-policy`):**
  - `tf-ruo`: samo zona `ruo.internal`, samo A/AAAA/CNAME/TXT/SRV, dakle ne NS ni SOA;
  - `tf-ptr`: samo PTR u reverznoj zoni.
- **Server:** `recursion no`; AXFR samo uz ključ; `serial-update-method unixtime`; `listen-on { localhost; }` (bez IP literala).
- **TTL:** 300 s za zapise, negativni TTL (SOA) 60 s.
- **Round-robin:** `var.servisi` mapira servis na listu VM-ova, pa je više VM-ova isto što i više A zapisa.
- **Bez sekundarnog servera.**

## Obrazloženje i posljedice

Šta se dobija:
- **`.internal`** je ICANN 2024. rezervisao za privatne mreže, pa se nikad neće sudariti s javnim DNS-om. `.local` je rezervisan za mDNS (RFC 6762) i sudara se s Avahi/systemd-resolved. `.lab` nije rezervisan i može postati javni TLD. `home.arpa` (RFC 8375) je namijenjen kućnim mrežama.
- **Servisna imena umjesto imena hostova.** Kod koristi `backend.ruo.internal`, ne `app1`, pa je premještanje servisa na drugi VM jedna stavka u `var.servisi`, bez izmjene aplikacije.
- **Najmanja prava.** Svaki ključ smije samo svoju zonu i samo potrebne tipove; ključ za zapise ne može preoteti delegaciju (NS). `tests/dns.sh` pokušava sve ostalo i dobija `REFUSED`.
- **Jedan vlasnik po zapisu.** Statička zona u Gitu (s5/p1) ima smisla kad ljudi ručno uređuju zapise; ovdje je svaki zapis ili infrastruktura (Ansible) ili servis (Terraform). Zato je dovoljna jedna dinamička zona, bez delegacije.
- **Drift se vidi i ispravlja.** `make drift-dns` mijenja zapise mimo koda (`nsupdate`); `terraform plan` to pokazuje (`1 to add, 1 to change`), a `apply` vraća stanje iz koda.
- **Server samo autoritativan.** `REFUSED` za tuđe domene sprječava zloupotrebu za DNS amplifikaciju, a AXFR bez ključa ne otkriva sva imena u mreži.
- **TTL 300 s** je kompromis između keširanja i brzine promjene. Negativni TTL 60 s znači da se novi zapis brzo vidi i nakon upita koji je dobio NXDOMAIN.

Šta se gubi:
- **Nema sekundarnog servera:** svjesno prihvaćen SPOF u labu. Dodavanje bi značilo ns2 na drugom VM-u, `notify yes`, `allow-transfer { key xfer; }` i dva resolvera u netplanu.
- **Sadržaj zone nije tekstualna datoteka u Gitu.** Kod zone je Terraform, a cijela zona se pregleda sa `dig AXFR` uz ključ.
- **Terraform vidi samo svoje zapise.** Zapis dodan ručno, a koji nije u kodu, plan ne prijavljuje.
- **TSIG zavisi od tačnog vremena** (razlika ≤ 5 min). Rješeno je sinhronizacijom sata VM-ova s hipervizorom (DO-4).

---

# DO-9: Upravljanje tajnama

Status: prihvaćeno

## Kontekst

Tajne projekta su lozinka baze, dva TSIG ključa, SSH ključ administratora i ključevi SSH servera. One nikad ne smiju biti u Gitu u čistom obliku; šifruju se `ansible-vault`-om ili se generišu pri pokretanju (AO-9). Na odbrani se provjerava historija repozitorija, a tajna koja je jednom ušla u historiju smatra se otkrivenom. U Git ide samo primjer (`vault.yml.example`).

## Razmotrene opcije

1. `.env` datoteka van Gita (tajne u čistom tekstu na disku).
2. `ansible-vault` s ručno upisanim vrijednostima.
3. Generisanje pri prvom pokretanju + čuvanje šifrovano `ansible-vault`-om, van Gita.
4. SOPS + age, ili HashiCorp Vault.

## Odluka

Opcija 3.

**Nastanak.** `make secrets` (`scripts/secrets.sh`) je idempotentan i pravi samo ono što nedostaje:
- `.vault_pass`: 32 nasumična bajta, prava 0600;
- `ansible/inventory/group_vars/all/vault.yml`: `vault_db_password` (`openssl rand -hex 24`) i `vault_tsig_tf_ruo`, `vault_tsig_tf_ptr` (`openssl rand -base64 32`, 256-bitni HMAC-SHA256 ključ). Datoteka se odmah šifruje (AES256).
- SSH ključ administratora je `~/.ssh/ruo_ed25519`, van repozitorija.

**Distribucija:**

| Kome | Kako |
|---|---|
| BIND (ns1) | `/etc/bind/ruo-keys.conf`, 0640 root:bind, `no_log: true` |
| backend (app1) | datoteka `/etc/ruo/secrets/db_password`, 0400, vlasnik UID 10001 (korisnik procesa u kontejneru); čita se preko `DB_PASSWORD_FILE` |
| baza (db1) | ista datoteka, 0400, vlasnik UID 70 (postgres); `POSTGRES_PASSWORD_FILE` |
| Terraform | `TF_VAR_*` iz `ansible-vault view` (`scripts/lib.sh tf-dns`), u memoriji; varijable su `sensitive` |
| `nsupdate` (drift, testovi) | privremena datoteka 0600, briše se pri izlazu; tajna nikad nije u argumentima naredbe |

**Zaštitne ograde:**
- `.gitignore` pokriva `.vault_pass`, `vault.yml`, `*.tfstate*`, `.env`, ključeve, generisani inventory i `known_hosts`;
- `tests/secrets.sh` (dio `make test`) provjerava da nijedna takva datoteka nije praćena **ni u jednom commitu** i da se **stvarne vrijednosti** tajni ne pojavljuju ni u jednoj verziji nijedne datoteke;
- `make destroy` briše tajne zajedno s okruženjem, a sljedeći `make all` pravi nove.

## Obrazloženje i posljedice

Šta se dobija:
- **Tajna nikad ne postoji u čistom obliku** u Gitu, u slici kontejnera, u varijablama okruženja ni u izlazu Ansible-a.
- **Datoteke umjesto varijabli okruženja.** Okruženje procesa se vidi u `docker inspect` i u `/proc/<pid>/environ`; datoteka s pravom 0400 je dostupna samo procesu kojem je namijenjena.
- **Okruženje je efemerno**, pa je generisanje prirodno: nema dijeljenih ni podrazumijevanih lozinki, a svako podizanje od nule dobija nove tajne.
- **Najmanja prava i kod tajni.** Svaki TSIG ključ je za jednu zonu (DO-8), a frontend nema nijednu tajnu.
- **Provjera nije samo pravilo nego test.** Test traži stvarne vrijednosti u cijeloj historiji. Kontrolno je provjereno da pretraga pronalazi string koji postoji, pa test ne prolazi „naprazno".

Šta se gubi:
- Gubitak `.vault_pass` znači da se vault ne može dešifrovati. Rješenje je `make destroy && make all`, uz nove tajne i nove podatke.
- Vault nije u Gitu, pa ga drugi član tima ne može dijeliti. U timskom radu vault bi se commitovao (šifrovan), a lozinka bi se dijelila kroz upravitelja lozinki ili tajnu u CI-ju.
- Terraform state sadrži privatne ključeve SSH servera i zato nikad ne smije u Git (pokriva `.gitignore`, provjerava test).
- SOPS + age ili HashiCorp Vault su moderniji standardi (rotacija, revizija pristupa), ali su izvan gradiva predmeta i bili bi novi servis koji treba štititi.
