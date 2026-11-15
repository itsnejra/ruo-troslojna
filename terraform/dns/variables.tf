# TSIG tajne: dolaze iz šifrovanog vault.yml kroz TF_VAR_* (scripts/tf-dns.sh), nikad s diska u
# čistom obliku (AO-9). sensitive: Terraform ih ne ispisuje u planu ni u izlazu.
variable "tsig_tf_ruo" {
  description = "TSIG tajna ključa tf-ruo (zona projekta)"
  type        = string
  sensitive   = true
}

variable "tsig_tf_ptr" {
  description = "TSIG tajna ključa tf-ptr (reverzna zona)"
  type        = string
  sensitive   = true
}

variable "servisi" {
  description = "Ime servisa -> VM-ovi koji ga nose. Više VM-ova = više A zapisa (round-robin)."
  type        = map(list(string))
  default = {
    frontend = ["web1"]
    backend  = ["app1"]
    db       = ["db1"]
  }
}

variable "aliasi" {
  description = "Dodatna imena (CNAME) -> servis na koji upućuju"
  type        = map(string)
  default = {
    www = "frontend" # korisnici otvaraju www.<zona>
  }
}

variable "ttl" {
  description = "TTL zapisa u sekundama (DO-8: kompromis između keširanja i brzine promjene)"
  type        = number
  default     = 300

  validation {
    condition     = var.ttl >= 30 && var.ttl <= 86400
    error_message = "TTL mora biti između 30 s i 1 dan."
  }
}
