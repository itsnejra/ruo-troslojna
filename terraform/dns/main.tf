# DNS zapisi projekta (AO-8, DO-8). Vlasništvo zapisa je podijeljeno i jasno:
#   * SOA, NS i glue zapis za DNS server postavlja Ansible (rola bind) jednom, pri nastanku zone,
#   * sve ostale zapise posjeduje Terraform (ovaj stack).
# Komponente se međusobno adresiraju SERVISNIM imenima (backend.<zona>), a ne imenima hostova:
# premještanje servisa na drugi VM je izmjena jedne stavke u var.servisi.

terraform {
  required_version = ">= 1.9"

  required_providers {
    # RFC 2136 (DNS UPDATE) potpisan TSIG ključem, kao s5/p2. Isti obrazac vrijedi za DNS u oblaku
    # (Route 53, Azure DNS): mijenja se samo provider, a zapisi ostaju resursi s planom, stanjem i driftom.
    dns = { source = "hashicorp/dns", version = "~> 3.4" }
  }
}

# Adrese i zona dolaze iz outputa stacka terraform/vm (AO-3), ne prepisuju se ručno.
data "terraform_remote_state" "vm" {
  backend = "local"
  config = {
    path = "${path.module}/../vm/terraform.tfstate"
  }
}

# Zona projekta: ključ tf-ruo smije mijenjati SAMO ovu zonu i samo A/AAAA/CNAME/TXT/SRV (AO-8).
provider "dns" {
  update {
    server        = local.dns_server
    key_name      = "tf-ruo."
    key_algorithm = "hmac-sha256"
    key_secret    = var.tsig_tf_ruo
  }
}

# Reverzna zona: poseban ključ tf-ptr, samo PTR zapisi (najmanja prava po ključu).
provider "dns" {
  alias = "ptr"
  update {
    server        = local.dns_server
    key_name      = "tf-ptr."
    key_algorithm = "hmac-sha256"
    key_secret    = var.tsig_tf_ptr
  }
}

locals {
  vm         = data.terraform_remote_state.vm.outputs
  zone       = "${local.vm.zone}."
  dns_server = local.vm.dns_server
  hosts      = local.vm.hosts
  dns_host   = [for name, h in local.hosts : name if h.ip == local.dns_server][0]

  # Reverzna zona /16 projekta iz adrese DNS servera: A.B.C.D -> B.A.in-addr.arpa.
  oktet        = split(".", local.dns_server)
  reverse_zone = "${local.oktet[1]}.${local.oktet[0]}.in-addr.arpa."
}

# Imena hostova (VM-ova). DNS server je izuzet: njegov A zapis je glue i pripada Ansible-u.
resource "dns_a_record_set" "host" {
  for_each = { for name, h in local.hosts : name => h if name != local.dns_host }

  zone      = local.zone
  name      = each.key
  addresses = [each.value.ip]
  ttl       = var.ttl
}

# Servisna imena: ovo koriste komponente aplikacije (frontend -> backend -> db).
resource "dns_a_record_set" "servis" {
  for_each = var.servisi

  zone      = local.zone
  name      = each.key
  addresses = sort([for h in each.value : local.hosts[h].ip])
  ttl       = var.ttl

  lifecycle {
    precondition {
      condition     = alltrue([for h in each.value : contains(keys(local.hosts), h)])
      error_message = "Servis ${each.key} upućuje na VM koji ne postoji u terraform/vm."
    }
  }
}

resource "dns_cname_record" "alias" {
  for_each = var.aliasi

  zone  = local.zone
  name  = each.key
  cname = "${each.value}.${local.zone}"
  ttl   = var.ttl

  lifecycle {
    precondition {
      condition     = contains(keys(var.servisi), each.value)
      error_message = "Alias ${each.key} upućuje na servis ${each.value} koji ne postoji u var.servisi."
    }
  }
}

# Oznaka vlasnika na vrhu zone: ko pregleda zonu (dig TXT) vidi da zapise vodi kod.
resource "dns_txt_record_set" "vlasnik" {
  zone = local.zone
  txt  = ["managed-by=terraform", "repo=ruo-troslojna/terraform/dns"]
  ttl  = var.ttl
}

# PTR (adresa -> ime) za svaki VM, u reverznoj zoni, drugim ključem.
resource "dns_ptr_record" "host" {
  for_each = local.hosts
  provider = dns.ptr

  zone = local.reverse_zone
  name = "${split(".", each.value.ip)[3]}.${split(".", each.value.ip)[2]}"
  ptr  = "${each.key}.${local.zone}"
  ttl  = var.ttl
}
