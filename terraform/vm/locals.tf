# Adresni plan kao izraz (DO-3): podmreže i adrese se računaju, ne prepisuju.
locals {
  segments = {
    for name, netnum in var.segments : name => {
      cidr    = cidrsubnet(var.project_cidr, 8, netnum)
      gateway = cidrhost(cidrsubnet(var.project_cidr, 8, netnum), 1) # host (bridge) je ruter segmenta
      prefix  = 24
      bridge  = "${var.name_prefix}-${name}"
    }
  }

  hosts = {
    for name, vm in var.vms : name => merge(vm, {
      ip      = cidrhost(local.segments[vm.segment].cidr, vm.hostnum)
      gateway = local.segments[vm.segment].gateway
      prefix  = local.segments[vm.segment].prefix
      fqdn    = "${name}.${var.zone}"
    })
  }

  # namespace ruo-klijent ("internet"): /30, host je .1, klijent .2
  client_cidr = cidrsubnet(cidrsubnet(var.project_cidr, 8, var.client_netnum), 6, 0)
  client = {
    cidr    = local.client_cidr
    host_ip = cidrhost(local.client_cidr, 1)
    ip      = cidrhost(local.client_cidr, 2)
    netns   = "${var.name_prefix}-klijent"
    veth    = "${var.name_prefix}-klijent" # sučelje na strani hosta
  }

  dns_ip         = local.hosts[var.dns_host].ip
  admin_pubkey   = trimspace(file(pathexpand(var.ssh_public_key_path)))
  admin_key_path = pathexpand(trimsuffix(var.ssh_public_key_path, ".pub"))
  repo_root      = abspath("${path.module}/../..")
  image_tag      = basename(dirname(var.base_image)) # build/image-<hash>/ruo-base.qcow2

  # Otisak svega što ulazi u cloud-init jednog VM-a (šabloni, adresa, slika, ključ administratora).
  # Bez tajni, pa nije "sensitive" i može biti dio imena ISO-a i instance-id.
  cloudinit_templates = join("", [for f in fileset("${path.module}/cloud-init", "*.tftpl") : file("${path.module}/cloud-init/${f}")])
  cloudinit_hash = {
    for name, h in local.hosts : name => substr(sha256(jsonencode([
      local.cloudinit_templates, h, local.image_tag, local.admin_pubkey, var.zone, local.dns_ip, var.admin_user,
    ])), 0, 10)
  }
}

# Sadržaj datoteka za Ansible (DO-6; datoteke piše main.tf): inventory i adresni plan.
locals {
  ansible_dir = "${local.repo_root}/ansible"

  inventory = {
    all = {
      children = {
        hypervisor = {
          hosts = { localhost = { ansible_connection = "local" } }
        }
        vms = {
          children = {
            for seg in keys(var.segments) : seg => {
              hosts = { for name, h in local.hosts : name => { ansible_host = h.ip } if h.segment == seg }
            }
          }
        }
      }
    }
  }

  generated_vars = {
    ruo_zone         = var.zone
    ruo_project_cidr = var.project_cidr
    ruo_dns_server   = local.dns_ip
    ruo_dns_host     = var.dns_host
    ruo_segments     = { for name, s in local.segments : name => { cidr = s.cidr, gateway = s.gateway, bridge = s.bridge } }
    ruo_hosts        = { for name, h in local.hosts : name => { ip = h.ip, segment = h.segment, fqdn = h.fqdn, data_disk = h.data_disk_gb > 0 } }
    ruo_client       = local.client
    ruo_image_tag    = local.image_tag
    ruo_admin_user   = var.admin_user

    # konekcija prema VM-ovima: ključ administratora i known_hosts iz Terraforma (bez isključivanja provjere)
    ansible_user                 = var.admin_user
    ansible_ssh_private_key_file = local.admin_key_path
    ansible_ssh_common_args      = "-o UserKnownHostsFile=${local.ansible_dir}/known_hosts -o StrictHostKeyChecking=yes"
  }
}
