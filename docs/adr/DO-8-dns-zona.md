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
