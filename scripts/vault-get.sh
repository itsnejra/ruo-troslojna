#!/usr/bin/env bash
# Ispisuje jednu vrijednost iz šifrovanog vault.yml (AO-9). Dešifruje se samo u memoriji,
# ništa se ne upisuje na disk.   scripts/vault-get.sh vault_tsig_tf_ruo
set -euo pipefail
cd "$(dirname "$0")/.."
ansible-vault view --vault-password-file .vault_pass ansible/inventory/group_vars/all/vault.yml \
  | python3 -c 'import sys, yaml; print(yaml.safe_load(sys.stdin)[sys.argv[1]])' "${1:?ime varijable}"
