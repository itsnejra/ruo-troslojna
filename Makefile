# Troslojna aplikacija kao kod: ulaz u sve korake. Pokretanje: `make help`.
# Stil prati Makefile predmeta: naredbe se ispisuju prije izvršavanja, ">" je prefiks recepta.
#
# Tok odbrane:  make destroy  ->  make all  ->  make test  ->  make all (drugi put: bez promjena)

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.RECIPEPREFIX := >
.DEFAULT_GOAL := help

DEV := docker compose -f app/compose.dev.yaml

# Zlatna slika (DO-4): oznaka je hash sadržaja mape packer/, pa se slika gradi ponovo samo kad
# se promijeni njen kod. Ista oznaka = ista slika = make image ne radi ništa (idempotentnost).
IMAGE_TAG := $(shell find packer -type f | LC_ALL=C sort | xargs cat | sha256sum | cut -c1-12)
IMAGE_DIR := build/image-$(IMAGE_TAG)
IMAGE     := $(CURDIR)/$(IMAGE_DIR)/ruo-base.qcow2

SSH_KEY  := $(HOME)/.ssh/ruo_ed25519
TF_VM    := terraform -chdir=terraform/vm
TF_DNS   := bash scripts/tf-dns.sh
# -K: sudo lozinka hosta (rola router mijenja host). Ako sudo ne traži lozinku: make ANSIBLE_ARGS= config
ANSIBLE_ARGS ?= -K
PLAYBOOK := cd ansible && ansible-playbook
VIRSH    := virsh -c qemu:///system

banner = printf '\n\033[1;36m== %s\033[0m\n' '$(1)'
need = command -v $(1) >/dev/null || { echo "Nedostaje '$(1)'. Vidi README.md (Preduslovi)."; exit 1; }

.PHONY: help check all test destroy distclean \
  ssh-key secrets image infra config dns images deploy \
  infra-plan dns-plan config-vms drift-dns \
  test-vm test-isolation test-dns test-ip test-app test-persist test-secrets \
  pdf dev-secret dev-up dev-test dev-persist dev-down dev-clean

##@ Glavni tok
help: ## ovaj popis
> @awk 'BEGIN{FS=":.*## "} /^##@/{printf "\n\033[1m%s\033[0m\n", substr($$0,5)} /^[a-zA-Z0-9_-]+:.*## /{printf "  \033[36m%-14s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)

check: ## provjera da su svi potrebni alati instalirani i da okruženje radi
> @ok=1; for t in git make curl openssl python3 docker terraform packer ansible-playbook ansible-vault virsh qemu-img dig nsupdate nft; do \
>   if command -v $$t >/dev/null; then printf '  \033[32mok\033[0m     %s\n' $$t; else printf '  \033[31mnema\033[0m   %s\n' $$t; ok=0; fi; done; \
> docker info >/dev/null 2>&1 && echo "  ok     docker daemon ($$(docker info --format '{{.OperatingSystem}}' 2>/dev/null))" || { echo "  !!     docker daemon ne radi (ili korisnik nije u grupi docker)"; ok=0; }; \
> case "$$(command -v docker)" in /mnt/*) echo "  napomena: docker je Docker Desktop; za build i docker save to radi, ali preporuka je Docker Engine u WSL-u";; esac; \
> [ -w /dev/kvm ] && echo "  ok     /dev/kvm" || { echo "  !!     /dev/kvm nije dostupan (KVM, grupa kvm)"; ok=0; }; \
> $(VIRSH) list >/dev/null 2>&1 && echo "  ok     libvirt (qemu:///system)" || { echo "  !!     libvirt ne radi (servis libvirtd, grupa libvirt)"; ok=0; }; \
> $(VIRSH) pool-info default >/dev/null 2>&1 && echo "  ok     libvirt pool default" || { echo "  !!     nema libvirt poola 'default' (00-setup.sh ga pravi)"; ok=0; }; \
> mem=$$(awk '/MemAvailable/{print int($$2/1048576)}' /proc/meminfo); \
> [ "$$mem" -ge 5 ] && echo "  ok     slobodna memorija: $${mem} GB" || echo "  !!     slobodna memorija $${mem} GB; 4 VM-a trebaju ~4,5 GB"; \
> case "$$(pwd)" in /mnt/*) echo "  !!     repozitorij je na /mnt/...: Ansible tada ignoriše ansible.cfg; klonirati u ~/"; ok=0;; esac; \
> for c in ansible.posix community.docker community.general; do \
>   ansible-galaxy collection list $$c 2>/dev/null | grep -q "^$$c " && echo "  ok     kolekcija $$c" || { echo "  !!     nema kolekcije $$c: ansible-galaxy collection install -r ansible/requirements.yml"; ok=0; }; done; \
> [ $$ok = 1 ] || { echo "Okruženje nije spremno (README.md, Preduslovi)."; exit 1; }

all: check secrets image infra config dns deploy ## sve redom: od praznog sistema do aplikacije koja radi
> @$(call banner,GOTOVO)
> @echo "  aplikacija:  http://www.$$($(TF_VM) output -raw zone)  (iz namespace-a klijenta: make test-app)"
> @echo "  provjera:    make test"

test: ## svi testovi (AO-1, AO-3..AO-10) sa sažetkom; traži sudo
> bash tests/run-all.sh

destroy: ## uklanja sve što je projekat kreirao (zlatna slika i arhive ostaju kao keš; vidi distclean)
> @$(call banner,1/4 DNS zapisi: dok DNS server još radi)
> @if [ -s terraform/dns/terraform.tfstate ]; then \
>   $(TF_DNS) destroy -auto-approve -input=false || { echo "DNS server nije dostupan: zapisi su nestali s njim, brišem stanje"; rm -f terraform/dns/terraform.tfstate*; }; \
> else echo "nema DNS zapisa"; fi
> @$(call banner,2/4 ruter i namespace klijenta na hostu)
> @if [ -f ansible/inventory/hosts.yml ]; then $(PLAYBOOK) teardown.yml $(ANSIBLE_ARGS); else echo "nema inventoryja (ruter nije postavljen)"; fi
> @$(call banner,3/4 VM-ovi, diskovi i mreže)
> @if [ -s terraform/vm/terraform.tfstate ]; then bash scripts/tf-retry.sh $(TF_VM) destroy -auto-approve -input=false; else echo "nema VM-ova"; fi
> @$(call banner,4/4 generisane datoteke, stanje i tajne)
> rm -f ansible/inventory/hosts.yml ansible/inventory/group_vars/all/generated.yml ansible/known_hosts
> rm -f terraform/vm/terraform.tfstate* terraform/dns/terraform.tfstate*
> rm -f .vault_pass ansible/inventory/group_vars/all/vault.yml
> @$(call banner,provjera: ništa od projekta ne smije ostati)
> @n=$$($(VIRSH) list --all --name | grep -c '^ruo-' || true); echo "  VM-ovi:  $$n"
> @n=$$($(VIRSH) net-list --all --name | grep -c '^ruo-' || true); echo "  mreže:   $$n"
> @n=$$($(VIRSH) vol-list default | grep -c ' ruo-' || true); echo "  diskovi: $$n"

distclean: destroy ## destroy + zlatna slika, arhive slika, Terraform provideri i lokalne Docker slike
> rm -rf build terraform/vm/.terraform terraform/dns/.terraform terraform/vm/image.auto.tfvars
> -docker image ls --format '{{.Repository}}:{{.Tag}}' | grep '^ruo/' | xargs -r docker rmi

##@ Koraci (all ih pokreće redom)
ssh-key: ## projektni SSH ključ administratora (~/.ssh/ruo_ed25519, van repozitorija)
> @test -f $(SSH_KEY) || { mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -q -t ed25519 -N "" -C "ruo-admin" -f $(SSH_KEY) && echo "napravljen $(SSH_KEY)"; }

secrets: ## tajne: .vault_pass i šifrovani vault.yml (samo ono što nedostaje; AO-9)
> @$(call need,ansible-vault)
> bash scripts/secrets.sh

image: ## Packer: zlatna slika VM-ova (preskače se ako slika za trenutni kod postoji)
> @$(call need,packer)
> @if [ -f "$(IMAGE)" ]; then echo "slika $(IMAGE_TAG) postoji: $(IMAGE)"; else \
>   $(call banner,packer build $(IMAGE_TAG)); \
>   packer init packer && packer validate -var image_tag=$(IMAGE_TAG) -var output_dir=$(IMAGE_DIR) packer && \
>   packer build -var image_tag=$(IMAGE_TAG) -var output_dir=$(IMAGE_DIR) packer; fi
> @# starije slike nisu potrebne: libvirt drži vlastitu kopiju u poolu
> @find build -maxdepth 1 -name 'image-*' ! -name 'image-$(IMAGE_TAG)' -exec rm -rf {} +
> @# putanja slike za Terraform: i obični `terraform plan` u terraform/vm radi bez dodatnih argumenata
> @printf '# GENERISANO: make image\nbase_image = "%s"\n' "$(IMAGE)" > terraform/vm/image.auto.tfvars

infra: ssh-key image ## Terraform: mreže, diskovi, VM-ovi, inventory i known_hosts (AO-3)
> @$(call need,terraform)
> $(TF_VM) init -input=false
> bash scripts/tf-retry.sh $(TF_VM) apply -auto-approve -input=false
> $(TF_VM) output hosts

config: secrets ## Ansible: ruter na hostu, vatrozid, Docker, DNS server (AO-5, AO-6, AO-7)
> @$(call need,ansible-playbook)
> @test -f ansible/inventory/hosts.yml || { echo "Nema inventoryja: prvo make infra"; exit 1; }
> $(PLAYBOOK) config.yml $(ANSIBLE_ARGS)

dns: secrets ## Terraform: DNS zapisi servisa, hostova i PTR (RFC 2136 + TSIG, AO-8)
> @$(call need,terraform)
> $(TF_DNS) init -input=false
> $(TF_DNS) apply -auto-approve -input=false
> $(TF_DNS) output servisi

images: ## Docker: build frontend/backend, zaključana slika baze, arhive za isporuku (DO-5)
> @$(call need,docker)
> bash scripts/build-images.sh

deploy: images ## Ansible: isporuka aplikacije na VM-ove (baza -> backend -> frontend)
> @test -f ansible/inventory/hosts.yml || { echo "Nema inventoryja: prvo make infra"; exit 1; }
> $(PLAYBOOK) deploy.yml

##@ Pregled i demonstracije
infra-plan: ## Terraform plan za VM-ove (nakon apply očekivano: No changes)
> bash scripts/tf-retry.sh $(TF_VM) plan -input=false

dns-plan: ## Terraform plan za DNS zapise (nakon apply očekivano: No changes)
> $(TF_DNS) plan -input=false

config-vms: secrets ## konfiguracija samo VM-ova (bez sudo na hostu)
> $(PLAYBOOK) config.yml --limit vms

drift-dns: ## drift: zapis mijenjamo mimo koda (nsupdate), plan ga vidi, apply ispravlja
> bash scripts/drift-dns.sh

##@ Pojedinačni testovi (make test pokreće sve)
test-vm: ## AO-3/AO-4: plan bez promjena, cloud-init, SSH ključem da, lozinkom ne, sat
> bash tests/vm.sh

test-isolation: ## AO-6: matrica povezivosti (sudo)
> bash tests/isolation.sh

test-dns: ## AO-7/AO-8: dig, PTR, REFUSED/NXDOMAIN, AXFR, prava TSIG ključeva, plan
> bash tests/dns.sh

test-ip: ## AO-7: nema IP literala u kodu izvan adresnog plana
> bash tests/no-ip-literals.sh

test-app: ## AO-1: aplikacija iz "interneta" (namespace klijenta, sudo)
> sudo ip netns exec ruo-klijent bash tests/app.sh http://www.$$($(TF_VM) output -raw zone)

test-persist: ## AO-10: unos, ponovno kreiranje kontejnera baze, provjera
> bash tests/persistence.sh

test-secrets: ## AO-9: nijedna tajna nije u Gitu (ni u historiji)
> bash tests/secrets.sh

##@ Dokumentacija
pdf: ## PDF za predaju iz docs/adr (REPO_URL=https://... make pdf)
> bash scripts/build-pdf.sh

##@ Razvoj aplikacije (lokalno, bez VM-ova)
dev-secret: ## lozinka baze za razvoj u .secrets/ (samo ako ne postoji; nije u Gitu)
> @$(call need,openssl)
> @mkdir -p .secrets && chmod 700 .secrets
> @test -s .secrets/db_password || { openssl rand -base64 24 | tr -d '\n' > .secrets/db_password; chmod 644 .secrets/db_password; echo "napravljena .secrets/db_password"; }

dev-up: dev-secret ## build i pokretanje sva tri sloja (http://localhost:8080)
> @$(call need,docker)
> $(DEV) up -d --build --wait
> $(DEV) ps

dev-test: ## provjera s kraja na kraj preko frontenda
> bash tests/app.sh http://localhost:8080

dev-persist: ## AO-10 lokalno: upis, ponovno kreiranje kontejnera baze, čitanje
> @$(call banner,upis markera)
> m="persist-$$(date +%s)"; curl -fsS -X POST -H 'Content-Type: application/json' -d "{\"text\":\"$$m\"}" localhost:8080/api/notes >/dev/null; echo "$$m" > .secrets/marker
> @$(call banner,ponovno kreiranje kontejnera baze)
> $(DEV) up -d --force-recreate --wait db
> @$(call banner,čitanje nakon recreate)
> curl -fsS localhost:8080/api/notes | grep -q "$$(cat .secrets/marker)" && echo "ok: podatak je preživio ponovno kreiranje kontejnera baze"

dev-down: ## zaustavlja kontejnere (podaci ostaju u volumenu)
> $(DEV) down

dev-clean: ## briše kontejnere i volumen s podacima
> $(DEV) down -v
