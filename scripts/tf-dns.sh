#!/usr/bin/env bash
# Terraform za DNS zapise (terraform/dns). TSIG tajne se čitaju iz vaulta i predaju Terraformu kroz
# varijable okruženja TF_VAR_* (obrazac "tf5" iz Makefilea predmeta), pa nikad nisu u datoteci.
#
#   scripts/tf-dns.sh plan | apply -auto-approve | destroy -auto-approve | output ...
set -euo pipefail
cd "$(dirname "$0")/.."
TF_VAR_tsig_tf_ruo="$(bash scripts/vault-get.sh vault_tsig_tf_ruo)"
TF_VAR_tsig_tf_ptr="$(bash scripts/vault-get.sh vault_tsig_tf_ptr)"
export TF_VAR_tsig_tf_ruo TF_VAR_tsig_tf_ptr
exec terraform -chdir=terraform/dns "$@"
