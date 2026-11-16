# Zapisi dizajnerskih odluka (ADR)

Svaka dizajnerska odluka (DO) iz projektnog zadatka ima jedan zapis, prema obrascu iz zadatka (isječak 1): Status, Kontekst, Razmotrene opcije, Odluka, Obrazloženje i posljedice. Odluka se ne briše kad se promijeni: novi ADR je zamjenjuje, a stari dobija status „zamijenjeno".

| DO | Pitanje | Izabrana opcija | Zapis |
|---|---|---|---|
| DO-1 | Aplikacija i tehnologije | vlastita aplikacija „Bilješke": nginx 1.27.5 · FastAPI (Python 3.12) · PostgreSQL 17.12 | [DO-1](DO-1-aplikacija.md) |
| DO-2 | Broj VM-ova i raspored | 4 VM-a (ns1, web1, app1, db1), libvirt `route` mreže, host je ruter s default deny, kontejneri na mreži VM-a | [DO-2](DO-2-raspored-vm.md) |
| DO-3 | Plan adresiranja | jedan literal `10.20.0.0/16`, segmenti `/24` (`cidrsubnet`), adrese `cidrhost`, statički preko netplana, bez DHCP-a | [DO-3](DO-3-adresiranje.md) |
| DO-4 | Bazna slika VM-a | vlastita Packer slika (Ubuntu 24.04 + Docker, nftables, BIND, chrony/ptp_kvm); cloud-init samo za instancu | [DO-4](DO-4-bazna-slika.md) |
| DO-5 | Slike kontejnera | build jednom na kontrolnom čvoru, oznaka = hash koda, bazne slike po digestu, isporuka kao arhiva | [DO-5](DO-5-slike-kontejnera.md) |
| DO-6 | Adrese za Ansible | Terraform generiše inventory, adresni plan i `known_hosts` (ključevi servera iz Terraforma) | [DO-6](DO-6-inventory.md) |
| DO-7 | Ansible role i varijable | role po funkciji (router, common, firewall, docker, bind, app); politika mreže kao podaci | [DO-7](DO-7-ansible-role.md) |
| DO-8 | DNS zona | `ruo.internal` + reverzna, jedan vlasnik po zapisu, TSIG ključ po zoni i tipu, TTL 300 s, bez sekundarnog | [DO-8](DO-8-dns-zona.md) |
| DO-9 | Tajne | generisanje pri prvom pokretanju + `ansible-vault`; datoteke 0400 umjesto varijabli okruženja; test historije | [DO-9](DO-9-tajne.md) |
