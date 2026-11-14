# Parametri infrastrukture (AO-3). Ovo je JEDINO mjesto u repozitoriju s IP literalom:
# sve podmreže i adrese se izvode iz project_cidr funkcijama cidrsubnet/cidrhost (DO-3),
# a ostatak sistema ih dobija iz outputa (inventory, DNS zapisi). Test tests/no-ip-literals.sh
# to provjerava.

variable "project_cidr" {
  description = "Supernet projekta; segmenti su /24 unutar njega"
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.project_cidr)) && endswith(var.project_cidr, "/16")
    error_message = "project_cidr mora biti IPv4 /16 mreža."
  }
}

variable "segments" {
  description = "Segmenti (ime -> redni broj /24 podmreže unutar project_cidr)"
  type        = map(number)
  default = {
    infra = 0 # DNS (zajednička infrastruktura)
    web   = 1 # frontend, jedini ulaz izvana
    app   = 2 # backend
    db    = 3 # baza, bez izlaza
  }

  validation {
    condition     = alltrue([for n in values(var.segments) : n >= 0 && n < 255])
    error_message = "Redni broj segmenta mora biti 0..254 (255 je rezervisan za klijentski namespace)."
  }
}

variable "client_netnum" {
  description = "Redni broj /24 iz kojeg se uzima /30 za namespace ruo-klijent (simulirani internet)"
  type        = number
  default     = 255
}

variable "vms" {
  description = "Virtuelne mašine: segment, redni broj hosta u podmreži i veličina"
  type = map(object({
    segment      = string
    hostnum      = number
    memory_mb    = optional(number, 1024)
    vcpu         = optional(number, 1)
    disk_gb      = optional(number, 10)
    data_disk_gb = optional(number, 0) # > 0: zaseban disk za podatke (AO-10)
  }))
  default = {
    ns1  = { segment = "infra", hostnum = 53, memory_mb = 768 }
    web1 = { segment = "web", hostnum = 10 }
    app1 = { segment = "app", hostnum = 10 }
    db1  = { segment = "db", hostnum = 10, memory_mb = 1536, data_disk_gb = 5 }
  }

  validation {
    condition     = alltrue([for v in values(var.vms) : contains(keys(var.segments), v.segment)])
    error_message = "Svaki VM mora biti u segmentu koji postoji u var.segments."
  }
  validation {
    condition     = alltrue([for v in values(var.vms) : v.memory_mb >= 512 && v.vcpu >= 1 && v.disk_gb >= 8])
    error_message = "VM treba najmanje 512 MB memorije, 1 vCPU i 8 GB diska."
  }
  validation {
    condition     = alltrue([for v in values(var.vms) : v.hostnum >= 10 && v.hostnum <= 254])
    error_message = "hostnum mora biti 10..254 (.1 je gateway, .2-.9 su rezerva)."
  }
}

variable "dns_host" {
  description = "VM koji nosi autoritativni DNS (njegova adresa je resolver svih VM-ova)"
  type        = string
  default     = "ns1"
}

variable "zone" {
  description = "DNS zona projekta (DO-8)"
  type        = string
  default     = "ruo.internal"
}

variable "base_image" {
  description = "Apsolutna putanja do Packer slike (postavlja make infra)"
  type        = string

  validation {
    condition     = startswith(var.base_image, "/") && fileexists(var.base_image)
    error_message = "base_image mora biti apsolutna putanja do postojeće slike (make image)."
  }
}

variable "admin_user" {
  description = "Korisnik za upravljanje (cloud-init, Ansible)"
  type        = string
  default     = "ops"
}

variable "ssh_public_key_path" {
  description = "Javni ključ administratora (make ssh-key)"
  type        = string
  default     = "~/.ssh/ruo_ed25519.pub"
}

variable "name_prefix" {
  description = "Prefiks imena libvirt objekata (da se ne sudare s labovima predmeta)"
  type        = string
  default     = "ruo"
}

variable "libvirt_uri" {
  type    = string
  default = "qemu:///system"
}

variable "pool" {
  description = "libvirt pool za diskove"
  type        = string
  default     = "default"
}
