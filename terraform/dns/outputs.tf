output "dns_server" {
  value = local.dns_server
}

output "zone" {
  value = local.zone
}

output "servisi" {
  description = "Servisno ime -> adrese"
  value       = { for name, r in dns_a_record_set.servis : "${name}.${local.zone}" => r.addresses }
}

output "hostovi" {
  value = merge(
    { for name, r in dns_a_record_set.host : "${name}.${local.zone}" => r.addresses },
    { "${local.dns_host}.${local.zone}" = [local.dns_server] } # glue (Ansible)
  )
}

output "aliasi" {
  value = { for name, r in dns_cname_record.alias : "${name}.${local.zone}" => r.cname }
}

output "ptr" {
  value = { for name, r in dns_ptr_record.host : local.hosts[name].ip => r.ptr }
}
