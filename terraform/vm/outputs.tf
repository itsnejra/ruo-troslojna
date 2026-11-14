# Outputi (AO-3): adrese i adresni plan. Čita ih i terraform/dns (terraform_remote_state).

output "hosts" {
  description = "VM -> adresa, segment, FQDN"
  value       = { for name, h in local.hosts : name => { ip = h.ip, segment = h.segment, fqdn = h.fqdn } }
}

output "segments" {
  description = "Segment -> podmreža i gateway"
  value       = { for name, s in local.segments : name => { cidr = s.cidr, gateway = s.gateway } }
}

output "client" {
  description = "Namespace koji glumi internet"
  value       = local.client
}

output "dns_server" {
  description = "Adresa autoritativnog DNS servera (za Terraform DNS provider)"
  value       = local.dns_ip
}

output "zone" {
  value = var.zone
}

output "admin_user" {
  value = var.admin_user
}

output "image_tag" {
  value = local.image_tag
}
