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
| Terraform | `TF_VAR_*` iz `ansible-vault view` (`scripts/tf-dns.sh`), u memoriji; varijable su `sensitive` |
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
