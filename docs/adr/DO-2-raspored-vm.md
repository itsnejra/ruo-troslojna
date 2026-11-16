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
