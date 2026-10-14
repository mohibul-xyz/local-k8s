output "ip_addresses" {
  description = "Fixed IPv4 address of each VM."
  value       = module.fleet.ip_addresses
}

output "inventory_path" {
  description = "Generated Ansible inventory."
  value       = module.fleet.inventory_path
}

output "ssh_commands" {
  description = "Ready-to-paste SSH command for each VM."
  value       = { for name, ip in module.fleet.ip_addresses : name => "ssh ${var.ssh_user}@${ip}" }
}
