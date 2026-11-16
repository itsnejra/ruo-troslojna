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
