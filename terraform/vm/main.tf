# Infrastruktura projekta (AO-3): mreže (segmenti), ključevi SSH servera, diskovi, VM-ovi i
# datoteke za Ansible. Ulazni podaci su u variables.tf, adrese se računaju u locals.tf (DO-3),
# a rezultati su u outputs.tf.

terraform {
  required_version = ">= 1.9" # validacije koje referenciraju druge varijable

  required_providers {
    # Serija 0.8 kao na vježbama (s2/p3): 0.9 ima drugačiju sintaksu resursa.
    libvirt = { source = "dmacvicar/libvirt", version = "~> 0.8.3" }
    tls     = { source = "hashicorp/tls", version = "~> 4.0" }
    local   = { source = "hashicorp/local", version = "~> 2.5" }
  }
}

provider "libvirt" {
  uri = var.libvirt_uri
}

# --- Mreže ---------------------------------------------------------------------------------
# Segmenti (AO-6, DO-2): po jedna libvirt mreža u route modu. Host je ruter između njih
# (kao ruo-rtr u s4/p2): nema NAT-a, nema DHCP-a ni dnsmasq DNS-a; adrese su statičke (DO-3),
# a ko s kim smije razgovarati određuje vatrozid na hostu (Ansible rola router).
resource "libvirt_network" "segment" {
  for_each = local.segments

  name      = each.value.bridge
  bridge    = each.value.bridge
  mode      = "route"
  addresses = [each.value.cidr]
  autostart = true

  dhcp {
    enabled = false
  }
  dns {
    enabled = false
  }
}

# --- Ključevi SSH servera --------------------------------------------------------------------
# Ključevi SSH servera (DO-6). Terraform ih pravi, cloud-init ih postavlja, a iz javnih dijelova
# nastaje ansible/known_hosts: kontrolni čvor provjerava identitet svakog VM-a od prvog spajanja.
# Privatni dijelovi su u Terraform stateu (koji nije u Gitu, AO-3/AO-9) i u cloud-init ISO-u u poolu.
resource "tls_private_key" "host" {
  for_each  = local.hosts
  algorithm = "ED25519"
}

# --- Diskovi -------------------------------------------------------------------------------
# Bazni volumen iz Packer slike. Ime nosi oznaku slike: nova slika = novi bazni volumen,
# pa Terraform zamjenjuje mašine (nepromjenjiva infrastruktura, mašine se ne "krpe").
resource "libvirt_volume" "base" {
  name   = "${var.name_prefix}-base-${local.image_tag}.qcow2"
  pool   = var.pool
  format = "qcow2"
  source = var.base_image
}

# root disk VM-a: qcow2 potomak bazne slike (piše samo svoje razlike)
resource "libvirt_volume" "root" {
  for_each = local.hosts

  name           = "${var.name_prefix}-${each.key}.qcow2"
  pool           = var.pool
  base_volume_id = libvirt_volume.base.id
  size           = each.value.disk_gb * 1024 * 1024 * 1024
}

# Zaseban disk za podatke (AO-10): životni ciklus podataka je odvojen od root diska VM-a,
# pa ni zamjena VM-a (npr. nova slika) ne briše bazu. Ansible ga formatira i montira.
resource "libvirt_volume" "data" {
  for_each = { for name, h in local.hosts : name => h if h.data_disk_gb > 0 }

  name   = "${var.name_prefix}-${each.key}-data.qcow2"
  pool   = var.pool
  format = "qcow2"
  size   = each.value.data_disk_gb * 1024 * 1024 * 1024
}

# --- cloud-init (AO-4) -----------------------------------------------------------------------
resource "libvirt_cloudinit_disk" "init" {
  for_each = local.hosts

  # Ime nosi hash ulaza: pri zamjeni stari i novi ISO nikad nemaju isto ime. Provider 0.8 čita
  # sadržaj ISO-a pri osvježavanju stanja; s istim imenom je zamjena znala pasti ("corrupted-image: EOF").
  name = "${var.name_prefix}-${each.key}-init-${local.cloudinit_hash[each.key]}.iso"
  pool = var.pool

  user_data = templatefile("${path.module}/cloud-init/user-data.tftpl", {
    hostname         = each.key
    zone             = var.zone
    admin_user       = var.admin_user
    admin_pubkey     = local.admin_pubkey
    host_key_private = tls_private_key.host[each.key].private_key_openssh
    host_key_public  = trimspace(tls_private_key.host[each.key].public_key_openssh)
  })

  network_config = templatefile("${path.module}/cloud-init/network-config.tftpl", {
    ip      = each.value.ip
    prefix  = each.value.prefix
    gateway = each.value.gateway
    dns_ip  = local.dns_ip
    zone    = var.zone
  })

  # instance-id nosi hash ulaza: novi ulaz = nova instanca, pa se cloud-init izvršava ponovo
  meta_data = <<-EOT
    instance-id: ${each.key}-${local.cloudinit_hash[each.key]}
    local-hostname: ${each.key}
  EOT
}

# --- Virtuelne mašine ------------------------------------------------------------------------
resource "libvirt_domain" "vm" {
  for_each = local.hosts

  name      = "${var.name_prefix}-${each.key}"
  memory    = each.value.memory_mb
  vcpu      = each.value.vcpu
  autostart = true # nakon restarta hosta mašine se same podižu
  cloudinit = libvirt_cloudinit_disk.init[each.key].id

  cpu {
    mode = "host-passthrough"
  }

  disk {
    volume_id = libvirt_volume.root[each.key].id
  }

  dynamic "disk" {
    for_each = contains(keys(libvirt_volume.data), each.key) ? [libvirt_volume.data[each.key].id] : []
    content {
      volume_id = disk.value
    }
  }

  network_interface {
    network_id = libvirt_network.segment[each.value.segment].id
  }

  console {
    type        = "pty"
    target_type = "serial"
    target_port = "0"
  }

  # Novi root disk (nova slika) ili novi cloud-init znače NOVU mašinu, a ne izmjenu definicije
  # pokrenute domene (koja bi i dalje radila sa starog diska do restarta). Disk s podacima
  # namjerno nije u listi: on preživljava zamjenu VM-a (AO-10).
  lifecycle {
    replace_triggered_by = [
      libvirt_volume.root[each.key].id,
      libvirt_cloudinit_disk.init[each.key].id,
    ]
  }
}

# --- Datoteke za Ansible (DO-6) ----------------------------------------------------------------
# Spona Terraform -> Ansible: inventory, adresni plan i known_hosts se generišu iz istih podataka
# iz kojih nastaju VM-ovi (sadržaj je u locals.tf). Datoteke su izvedeni artefakti i nisu u Gitu.
resource "local_file" "inventory" {
  filename        = "${local.ansible_dir}/inventory/hosts.yml"
  file_permission = "0644"
  content         = "# GENERISANO: terraform/vm/main.tf. Ne mijenjati ručno.\n${yamlencode(local.inventory)}"
}

resource "local_file" "generated_vars" {
  filename        = "${local.ansible_dir}/inventory/group_vars/all/generated.yml"
  file_permission = "0644"
  content         = "# GENERISANO: terraform/vm/main.tf. Ne mijenjati ručno.\n${yamlencode(local.generated_vars)}"
}

resource "local_file" "known_hosts" {
  filename        = "${local.ansible_dir}/known_hosts"
  file_permission = "0644"
  content = join("", [
    for name, h in local.hosts :
    "${h.ip},${name},${h.fqdn} ${trimspace(tls_private_key.host[name].public_key_openssh)}\n"
  ])
}
