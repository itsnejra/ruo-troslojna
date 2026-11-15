# Troslojna aplikacija kao kod: ulaz u sve korake. Pokretanje: `make help`.
# Stil prati Makefile predmeta: naredbe se ispisuju prije izvršavanja, ">" je prefiks recepta.
# Gotovo: image, infra (faza 2). Slijede config, dns, deploy, test, all, destroy.

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

SSH_KEY := $(HOME)/.ssh/ruo_ed25519
TF_VM   := terraform -chdir=terraform/vm
# -K: sudo lozinka hosta (rola router mijenja host). Ako sudo ne traži lozinku: make ANSIBLE_ARGS= config
ANSIBLE_ARGS ?= -K
PLAYBOOK := cd ansible && ansible-playbook
TF_DNS   := bash scripts/tf-dns.sh

banner = printf '\n\033[1;36m== %s\033[0m\n' '$(1)'
need = command -v $(1) >/dev/null || { echo "Nedostaje '$(1)'. Vidi README.md (Preduslovi)."; exit 1; }

.PHONY: help check image ssh-key infra infra-plan infra-destroy test-vm test-ip test-isolation test-dns \
  test-app test-persist secrets config config-vms dns dns-plan drift-dns dns-destroy images deploy dev-secret dev-up dev-test dev-persist dev-down dev-clean

##@ Pomoć
help: ## ovaj popis
> @awk 'BEGIN{FS=":.*## "} /^##@/{printf "\n\033[1m%s\033[0m\n", substr($$0,5)} /^[a-zA-Z0-9_-]+:.*## /{printf "  \033[36m%-14s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)

check: ## provjera alata i okruženja
> @for t in git make curl openssl docker terraform ansible-playbook packer virsh; do \
>   if command -v $$t >/dev/null; then printf '  \033[32mok\033[0m     %-16s %s\n' $$t "$$(command -v $$t)"; \
>   else printf '  \033[33mnema\033[0m   %s\n' $$t; fi; done
> @docker info >/dev/null 2>&1 && echo "  ok     docker daemon radi" || echo "  !!     docker daemon ne radi"
> @[ -w /dev/kvm ] && echo "  ok     /dev/kvm" || echo "  !!     /dev/kvm nije dostupan"
> @case "$$(command -v docker)" in /mnt/*) echo "  !!     docker pokazuje na Windows (Docker Desktop); koristiti Docker Engine u WSL-u";; esac

##@ Infrastruktura
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

ssh-key: ## projektni SSH ključ administratora (~/.ssh/ruo_ed25519, van repozitorija)
> @test -f $(SSH_KEY) || { mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -q -t ed25519 -N "" -C "ruo-admin" -f $(SSH_KEY) && echo "napravljen $(SSH_KEY)"; }

infra: ssh-key image ## Terraform: mreže, diskovi, VM-ovi, inventory i known_hosts (AO-3)
> @$(call need,terraform)
> @virsh -c qemu:///system list >/dev/null 2>&1 || { echo "libvirt ne radi (virsh -c qemu:///system list)"; exit 1; }
> $(TF_VM) init -input=false
> bash scripts/tf-retry.sh $(TF_VM) apply -auto-approve -input=false
> $(TF_VM) output hosts

infra-plan: ## Terraform plan za VM-ove (nakon apply očekivano: No changes)
> bash scripts/tf-retry.sh $(TF_VM) plan -input=false

test-vm: ## AO-3/AO-4: plan bez promjena, cloud-init, SSH ključem da, lozinkom ne
> bash tests/vm.sh

test-isolation: ## AO-6: matrica povezivosti (traži sudo: promet iz namespace-a klijenta)
> bash tests/isolation.sh

test-dns: ## AO-7/AO-8: dig upiti, PTR, rekurzija, AXFR, prava TSIG ključeva, plan bez promjena
> bash tests/dns.sh

test-app: ## AO-1: aplikacija s kraja na kraj iz "interneta" (namespace klijenta, sudo)
> sudo ip netns exec ruo-klijent bash tests/app.sh http://www.$$(terraform -chdir=terraform/vm output -raw zone)

test-persist: ## AO-10: unos, ponovno kreiranje kontejnera baze, provjera
> bash tests/persistence.sh

test-ip: ## AO-7: nema IP literala u kodu izvan adresnog plana
> bash tests/no-ip-literals.sh

secrets: ## tajne: .vault_pass i šifrovani vault.yml (samo ono što nedostaje; AO-9)
> @$(call need,ansible-vault)
> bash scripts/secrets.sh

config: secrets ## Ansible: ruter na hostu, vatrozid, Docker, DNS server (AO-5, AO-6, AO-7)
> @$(call need,ansible-playbook)
> @test -f ansible/inventory/hosts.yml || { echo "Nema inventoryja: prvo make infra"; exit 1; }
> $(PLAYBOOK) config.yml $(ANSIBLE_ARGS)

config-vms: secrets ## isto kao config, ali samo VM-ovi (bez sudo na hostu)
> $(PLAYBOOK) config.yml --limit vms

dns: secrets ## Terraform: DNS zapisi servisa, hostova i PTR (RFC 2136 + TSIG, AO-8)
> @$(call need,terraform)
> $(TF_DNS) init -input=false
> $(TF_DNS) apply -auto-approve -input=false
> $(TF_DNS) output servisi

dns-plan: ## Terraform plan za DNS zapise (nakon apply očekivano: No changes)
> $(TF_DNS) plan -input=false

drift-dns: ## demonstracija drifta: zapis mijenjamo mimo koda (nsupdate), plan ga vidi, apply ispravlja
> bash scripts/drift-dns.sh

images: ## Docker: build frontend/backend, zaključana slika baze, arhive za isporuku (DO-5)
> @$(call need,docker)
> bash scripts/build-images.sh

deploy: images ## Ansible: isporuka aplikacije na VM-ove (baza -> backend -> frontend)
> @test -f ansible/inventory/hosts.yml || { echo "Nema inventoryja: prvo make infra"; exit 1; }
> $(PLAYBOOK) deploy.yml

dns-destroy: ## uklanja DNS zapise (dok DNS server još radi)
> -$(TF_DNS) destroy -auto-approve -input=false

infra-destroy: ## uklanja ruter s hosta, VM-ove, diskove i mreže
> -test -f ansible/inventory/hosts.yml && $(PLAYBOOK) teardown.yml $(ANSIBLE_ARGS)
> -$(TF_VM) destroy -auto-approve -input=false
> rm -f ansible/inventory/hosts.yml ansible/inventory/group_vars/all/generated.yml ansible/known_hosts

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
