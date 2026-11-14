# Zlatna slika projekta (DO-4). Polazište: s2/p4/ubuntu.pkr.hcl.
#
# U slici je sve što je ISTO za sve VM-ove i rijetko se mijenja (Docker, nftables, BIND, alati),
# pa VM-ovima pri radu ne treba izlaz na internet (DO-2: segmenti bez izlaza).
# Ono što je specifično za instancu (ime, korisnik, ključevi, adresa) dodaje cloud-init pri pokretanju.
#
#   make image      gradi sliku samo ako slika za trenutni sadržaj mape packer/ ne postoji

packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "~> 1.1"
    }
  }
}

variable "image_tag" {
  type        = string
  description = "Oznaka slike: hash sadržaja mape packer/ (računa ga Makefile)"
}

variable "output_dir" {
  type        = string
  description = "Direktorij u koji se upisuje gotova slika (ne smije postojati)"
}

variable "ubuntu_image_url" {
  type    = string
  default = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

variable "ubuntu_checksum" {
  type    = string
  default = "file:https://cloud-images.ubuntu.com/noble/current/SHA256SUMS"
}

# Lozinka postoji samo dok traje izgradnja: nasumična je pri svakom pokretanju, nije u Gitu,
# a provisioner je na kraju zaključava (s2/p4 je imao "packer" upisano u kod).
# sensitive: Packer je ne ispisuje ni u porukama o greškama.
local "build_password" {
  expression = uuidv4()
  sensitive  = true
}

locals {
  root = abspath(path.root) # Packer relativne putanje u funkcijama računa od mape konfiguracije
}

source "qemu" "ruo" {
  iso_url          = var.ubuntu_image_url
  iso_checksum     = var.ubuntu_checksum
  disk_image       = true # ulaz je gotov disk (cloud slika), ne instalacijski ISO
  format           = "qcow2"
  disk_size        = "10G"
  disk_compression = true
  memory           = 2048
  cpus             = 2
  accelerator      = "kvm"
  headless         = true
  qemuargs         = [["-cpu", "host"]]

  # NoCloud izvor za cloud-init build mašine: privremeni cidata ISO sa sadržajem iz koda
  cd_label = "cidata"
  cd_content = {
    "user-data" = templatefile("${local.root}/seed/user-data.pkrtpl", { password = local.build_password })
    "meta-data" = "instance-id: ruo-packer-${var.image_tag}\n"
  }

  ssh_username     = "ubuntu"
  ssh_password     = local.build_password
  ssh_timeout      = "10m"
  shutdown_command = "sudo shutdown -P now"

  output_directory = var.output_dir
  vm_name          = "ruo-base.qcow2"
}

build {
  sources = ["source.qemu.ruo"]

  provisioner "shell" {
    script           = "${local.root}/scripts/provision.sh"
    execute_command  = "{{ .Vars }} sudo -E bash '{{ .Path }}'" # {{ .Vars }} prenosi environment_vars
    environment_vars = ["RUO_IMAGE_TAG=${var.image_tag}"]
  }
}
