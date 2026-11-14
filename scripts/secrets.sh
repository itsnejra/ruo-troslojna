#!/usr/bin/env bash
# Tajne projekta (AO-9, DO-9): generišu se pri prvom pokretanju i čuvaju šifrovane ansible-vaultom.
# Idempotentno: pravi se samo ono što nedostaje, postojeće tajne se ne mijenjaju.
#
#   .vault_pass                               lozinka za vault (0600, nije u Gitu)
#   ansible/inventory/group_vars/all/vault.yml šifrovano (AES256), nije u Gitu; obrazac: vault.yml.example
set -euo pipefail
cd "$(dirname "$0")/.."

PASS=.vault_pass
VAULT=ansible/inventory/group_vars/all/vault.yml
umask 077

if [ ! -s "$PASS" ]; then
  openssl rand -base64 32 > "$PASS"
  echo "napravljen $PASS"
fi

if [ ! -s "$VAULT" ]; then
  mkdir -p "$(dirname "$VAULT")"
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  # hex za lozinku baze: bez znakova koji bi smetali u connection stringu
  # base64 od 32 bajta za TSIG: 256-bitni HMAC-SHA256 ključ (isti oblik kao tsig-keygen)
  cat > "$tmp" <<EOF
vault_db_password: "$(openssl rand -hex 24)"
vault_tsig_tf_ruo: "$(openssl rand -base64 32)"
vault_tsig_tf_ptr: "$(openssl rand -base64 32)"
EOF
  ansible-vault encrypt --vault-password-file "$PASS" --output "$VAULT" "$tmp" >/dev/null
  echo "napravljen $VAULT (šifrovan)"
fi

head -1 "$VAULT" | grep -q '^\$ANSIBLE_VAULT;1.1;AES256' || { echo "GREŠKA: $VAULT nije šifrovan"; exit 1; }
echo "tajne: ok ($PASS, $VAULT)"
