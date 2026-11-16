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

Opcija 2, proširena (`terraform/vm/inventory.tf`). Iz istih podataka iz kojih pravi VM-ove, Terraform generiše tri datoteke:

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
