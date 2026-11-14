# Ključevi SSH servera (DO-6). Terraform ih pravi, cloud-init ih postavlja, a iz javnih dijelova
# nastaje ansible/known_hosts: kontrolni čvor provjerava identitet svakog VM-a od prvog spajanja.
# Privatni dijelovi su u Terraform stateu (koji nije u Gitu, AO-3/AO-9) i u cloud-init ISO-u u poolu.
resource "tls_private_key" "host" {
  for_each  = local.hosts
  algorithm = "ED25519"
}
