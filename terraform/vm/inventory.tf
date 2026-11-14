# Spona Terraform -> Ansible (DO-6): inventory, adresni plan i known_hosts se generišu iz istih
# podataka iz kojih nastaju VM-ovi. Datoteke su izvedeni artefakti i nisu u Gitu.

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

resource "local_file" "inventory" {
  filename        = "${local.ansible_dir}/inventory/hosts.yml"
  file_permission = "0644"
  content         = "# GENERISANO: terraform/vm/inventory.tf. Ne mijenjati ručno.\n${yamlencode(local.inventory)}"
}

resource "local_file" "generated_vars" {
  filename        = "${local.ansible_dir}/inventory/group_vars/all/generated.yml"
  file_permission = "0644"
  content         = "# GENERISANO: terraform/vm/inventory.tf. Ne mijenjati ručno.\n${yamlencode(local.generated_vars)}"
}

resource "local_file" "known_hosts" {
  filename        = "${local.ansible_dir}/known_hosts"
  file_permission = "0644"
  content = join("", [
    for name, h in local.hosts :
    "${h.ip},${name},${h.fqdn} ${trimspace(tls_private_key.host[name].public_key_openssh)}\n"
  ])
}
