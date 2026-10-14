output "ids" {
  description = "VirtualBox UUID of each VM, keyed by name."
  value       = { for name, vm in module.vm : name => vm.ids[name] }
}

output "ip_addresses" {
  description = "Fixed IPv4 address of each VM, keyed by name."
  value       = { for name, vm in var.vms : name => vm.ip }
}

output "reported_ip_addresses" {
  description = "IPv4 address each VM's primary adapter last reported through Guest Additions (its DHCP address until the fixed IP is applied)."
  value       = local.ip_addresses
}

output "inventory" {
  description = "The generated Ansible inventory, as YAML."
  value       = yamlencode(local.inventory)
}

output "inventory_path" {
  description = "Path of the written inventory file, or null if none was written."
  value       = one(local_file.inventory[*].filename)
}

output "ansible_run_id" {
  description = "Changes every time the playbook runs; null when ansible_playbook is unset. Depend on it to wait for provisioning."
  value       = one(terraform_data.ansible[*].id)
}
