# Virtuelne mašine (AO-3): disk iz zlatne slike, cloud-init (AO-4) i domena.

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

resource "libvirt_cloudinit_disk" "init" {
  for_each = local.hosts

  # Ime nosi hash ulaza: pri zamjeni stari i novi ISO nikad nemaju isto ime. Provider 0.8 čita
  # sadržaj ISO-a pri osvježavanju stanja; s istim imenom je zamjena znala pasti ("corrupted-image: EOF").
  name = "${var.name_prefix}-${each.key}-init-${local.cloudinit_hash[each.key]}.iso"
  pool = var.pool

  user_data = templatefile("${local.repo_root}/cloud-init/user-data.tftpl", {
    hostname         = each.key
    zone             = var.zone
    admin_user       = var.admin_user
    admin_pubkey     = local.admin_pubkey
    host_key_private = tls_private_key.host[each.key].private_key_openssh
    host_key_public  = trimspace(tls_private_key.host[each.key].public_key_openssh)
  })

  network_config = templatefile("${local.repo_root}/cloud-init/network-config.tftpl", {
    ip      = each.value.ip
    prefix  = each.value.prefix
    gateway = each.value.gateway
    dns_ip  = local.dns_ip
    zone    = var.zone
  })

  meta_data = templatefile("${local.repo_root}/cloud-init/meta-data.tftpl", {
    hostname    = each.key
    instance_id = "${each.key}-${local.cloudinit_hash[each.key]}"
  })
}

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
