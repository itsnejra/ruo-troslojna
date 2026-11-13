# Troslojna aplikacija kao kod: ulaz u sve korake. Pokretanje: `make help`.
# Stil prati Makefile predmeta: naredbe se ispisuju prije izvršavanja, ">" je prefiks recepta.
# Ciljevi infrastrukture (image, infra, config, dns, deploy, test, all, destroy) dolaze u sljedećim fazama.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.RECIPEPREFIX := >
.DEFAULT_GOAL := help

DEV := docker compose -f app/compose.dev.yaml

banner = printf '\n\033[1;36m== %s\033[0m\n' '$(1)'
need = command -v $(1) >/dev/null || { echo "Nedostaje '$(1)'. Vidi README.md (Preduslovi)."; exit 1; }

.PHONY: help check dev-secret dev-up dev-test dev-persist dev-down dev-clean

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
