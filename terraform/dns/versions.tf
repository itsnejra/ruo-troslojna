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
