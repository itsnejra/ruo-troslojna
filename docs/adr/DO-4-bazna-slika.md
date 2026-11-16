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

cloud-init (`cloud-init/*.tftpl`) radi samo ono što je specifično za instancu:
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
