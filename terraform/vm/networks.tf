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
