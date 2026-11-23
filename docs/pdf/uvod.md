---
title: "Troslojna aplikacija kao kod"
lang: bs
---

<div class="naslovna">
<p class="ustanova">Univerzitet u Zenici · Politehnički fakultet</p>
<p class="predmet">Računarstvo u oblaku · II ciklus, III semestar · akademska 2026/27</p>
<h1 class="naslov">Troslojna aplikacija kao kod</h1>
<p class="podnaslov">Projektni zadatak: dizajnerske odluke (DO) i zapisi arhitektonskih odluka (ADR)</p>
<table class="podaci">
<tr><th>Student</th><td>@@AUTOR@@</td></tr>
<tr><th>Repozitorij</th><td><a href="@@REPO@@">@@REPO@@</a></td></tr>
<tr><th>Nastavnik</th><td>V. prof. dr. Đulaga Hadžić</td></tr>
<tr><th>Asistent</th><td>ass. Mr. Adin Jahić</td></tr>
<tr><th>Predaja</th><td>srijeda, 25.11.2026</td></tr>
</table>
</div>

# Opis aplikacije i arhitekture

## Aplikacija

„Trezor" je vlastita, namjerno mala web aplikacija za povjerljive bilješke: korisnik upiše bilješku, ona se sačuva u bazu i prikaže u listi. Podaci su povjerljivi, pa je cilj infrastrukture da napadač koji preuzme izloženi frontend nema put do baze i da podaci ne mogu izaći van; iz tog cilja dolaze odluke DO-2 i DO-9. Aplikacija nije predmet ocjenjivanja: služi da kroz sva tri sloja prođe stvaran zahtjev sa stvarnim podacima, i da se može objasniti red po red.

| Sloj | Tehnologija | Adresira sljedeći sloj |
|---|---|---|
| frontend | nginx 1.27.5: statični HTML/JS i reverse proxy `/api/` | `backend.ruo.internal:8000` |
| backend | Python 3.12.16, FastAPI, psycopg 3 | `db.ruo.internal:5432` |
| baza | PostgreSQL 17.12 | — |

## Arhitektura

Sistem čine četiri virtuelne mašine na KVM/libvirt hipervizoru (WSL2). Svaki sloj aplikacije radi u svom Docker kontejneru, na svom VM-u, u svom mrežnom segmentu. Autoritativni DNS je na zasebnom VM-u u infrastrukturnom segmentu. Host usmjerava promet između segmenata i na njemu je centralni vatrozid s pravilom „sve je zabranjeno osim nabrojanog". Svaki VM ima i vlastiti vatrozid. „Internet" je mrežni namespace spojen na host, pa njegov promet prolazi kroz ruter kao pravi promet izvana.

![Stvarni raspored: host je ruter između četiri segmenta; dozvoljeni su samo tokovi internet → web1 :80, web1 → app1 :8000, app1 → db1 :5432 i svi → ns1 :53](docs/dijagram.png)

| Tok | Port | Dozvoljen |
|---|---|---|
| klijent → frontend | tcp/80 | da: jedini ulaz izvana |
| frontend → backend | tcp/8000 | da |
| backend → baza | tcp/5432 | da |
| svi segmenti → DNS | tcp+udp/53 | da |
| frontend → baza, obrnuti smjerovi, izlaz na internet, sve ostalo | | **ne** |

Kompletna infrastruktura je kod, a svaka obavezna arhitektonska odluka ima automatski test:

| Alat | Uloga |
|---|---|
| Packer | zlatna slika VM-ova |
| Terraform | VM-ovi, mreže, diskovi, inventory za Ansible; DNS zapisi preko RFC 2136 + TSIG |
| cloud-init | korisnik sa SSH ključem, bez lozinke |
| Ansible | ruter, vatrozid, Docker, BIND, isporuka aplikacije |

Cijeli tok je `make destroy` → `make all` (1 min 11 s od praznog sistema) → `make test` (svi testovi prolaze) → `make all` (bez promjena).

| AO | Kako je ispunjena | Dokaz |
|---|---|---|
| AO-1 | tri kontejnera, tok samo frontend → backend → baza | test aplikacije iz „interneta" |
| AO-2 | `make all` / `make destroy`, bez ručnih koraka | ciklus od nule |
| AO-3 | Terraform, parametri su varijable s validacijom, adrese su outputi, state nije u Gitu | `terraform plan`: bez promjena |
| AO-4 | cloud-init: korisnik `ops` s ključem, `ssh_pwauth: false` | SSH ključem da, lozinkom ne |
| AO-5 | Ansible role, idempotentno | drugi run: `changed=0` na svim hostovima |
| AO-6 | 4 segmenta, ruter + vatrozid VM-a, baza bez objavljenog porta | matrica povezivosti 14/14 |
| AO-7 | BIND, zona `ruo.internal`; u kodu samo DNS imena | `dig` upiti; pretraga koda: jedini IP je `project_cidr` |
| AO-8 | Terraform `hashicorp/dns`; TSIG ključ samo za svoju zonu i tipove | `REFUSED` izvan prava; drift otkriven i ispravljen |
| AO-9 | tajne generisane i šifrovane ansible-vaultom; datoteke 0400 | pretraga cijele git historije |
| AO-10 | podaci na zasebnom disku VM-a | podatak preživi `--force-recreate` i `docker rm -f` |

# Pregled dizajnerskih odluka

| DO | Pitanje | Izabrana opcija |
|---|---|---|
| DO-1 | Aplikacija i tehnologije | vlastita aplikacija „Trezor" (povjerljive bilješke): nginx · FastAPI (Python) · PostgreSQL |
| DO-2 | Broj VM-ova i raspored | 4 VM-a (ns1, web1, app1, db1); libvirt `route` mreže; host je ruter s default deny; DNS na zasebnom VM-u; kontejneri na mreži VM-a |
| DO-3 | Plan adresiranja | jedan literal `10.20.0.0/16`; segmenti `/24` (`cidrsubnet`), adrese `cidrhost`; statičke adrese preko netplana, bez DHCP-a |
| DO-4 | Bazna slika VM-a | vlastita Packer slika (Ubuntu 24.04 + Docker, nftables, BIND, chrony/ptp_kvm); cloud-init samo za instancu |
| DO-5 | Slike kontejnera | build jednom na kontrolnom čvoru; oznaka = hash koda; bazne slike po digestu; isporuka kao arhiva (bez registryja) |
| DO-6 | Adrese VM-ova za Ansible | Terraform generiše inventory, adresni plan i `known_hosts` (ključevi servera iz Terraforma) |
| DO-7 | Ansible role i varijable | role po funkciji (router, firewall, docker, bind, app); sva konfiguracija servera u rolama; mrežna politika kao podaci; `vault_` prefiks |
| DO-8 | DNS zona | `ruo.internal` + reverzna; jedan vlasnik po zapisu; TSIG ključ po zoni i tipu zapisa; TTL 300 s; bez sekundarnog |
| DO-9 | Tajne | generisanje pri prvom pokretanju + ansible-vault; datoteke 0400 umjesto varijabli okruženja; test historije |

Na sljedećim stranicama je po jedan zapis (ADR) za svaku odluku, prema obrascu iz zadatka. Isti zapisi su u repozitoriju, u `docs/ADR.md`.
