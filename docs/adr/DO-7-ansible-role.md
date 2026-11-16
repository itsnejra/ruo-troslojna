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

Opcija 2.

| Rola | Hostovi | Zadatak |
|---|---|---|
| `router` | hypervisor (host) | tabela `inet ruo3t`: default deny za projektna sučelja, namespace klijenta, `ip_forward` |
| `common` | svi VM-ovi | čekanje SSH-a i cloud-inita (obrazac s3/p3), činjenice, `/etc/ruo` |
| `firewall` | svi VM-ovi | nftables `input` iz politike; `validate: nft -c`; provjera da su pravila učitana u jezgru |
| `docker` | web, app, db | `daemon.json` (bez iptables-a, bez bridgea), servis |
| `bind` | infra | BIND: opcije, zone, TSIG ključevi, početne zone (`force: false`) |
| `app` | web, app, db | disk za podatke, tajna, `pg_hba.conf`, slike, `docker compose --profile <sloj>` |

Playbookovi: `config.yml` (router, common, firewall, docker, bind), `deploy.yml` (app: baza → backend → frontend), `teardown.yml` (router, stanje „nema").

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
- **Politika je na jednom mjestu.** Iz `mreza_politika` nastaju i pravila rutera i ulazna pravila VM-ova, pa se dva nivoa zaštite ne mogu razići. Nova dozvola je jedan red podataka (proširenje s4/p4).
- **Idempotentnost i konvergencija.** Šabloni s `validate` mijenjaju datoteku samo kad se sadržaj promijeni, a handleri reaguju samo na promjenu. Provjere stanja jezgre (pravila učitana?) vraćaju sistem u željeno stanje i nakon restarta WSL-a, a javljaju `changed` samo kad stvarno moraju nešto uraditi. Izmjereno: drugi `make all` daje `changed=0` na svih pet hostova.
- **Redoslijed isporuke prati zavisnosti**, a svaki sloj se čeka dok ne postane zdrav.

Šta se gubi:
- Rola `app` je generička, pa se ponašanje po hostu čita iz `group_vars`; to traži poznavanje prioriteta varijabli.
- Rola `router` traži sudo lozinku hosta (`-K`). Bez toga se mogu konfigurisati samo VM-ovi (`make config-vms`).
- `ansible.posix.sysctl` i `mount` ispisuju upozorenje o zastarjelim internim API-jima iz kolekcije. Upozorenje dolazi iz kolekcije, ne iz projekta, i ne utiče na rezultat.
