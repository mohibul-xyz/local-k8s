output "names" {
  description = "Names of the created VMs, in order."
  value       = local.names
}

output "ids" {
  description = "VirtualBox UUID of each VM, keyed by name."
  value       = { for name, vm in virtualbox_vm.this : name => vm.id }
}

output "primary_ipv4_addresses" {
  description = "IPv4 address of the primary adapter (see primary_adapter_index) of each VM, keyed by name. Reported by the guest, so the box needs VirtualBox Guest Additions."
  value       = { for name, vm in virtualbox_vm.this : name => vm.network_adapter[local.primary_adapter_index].ipv4_address }
}

output "ipv4_addresses" {
  description = "IPv4 address of every adapter of each VM (in slot order), keyed by name."
  value       = { for name, vm in virtualbox_vm.this : name => vm.network_adapter[*].ipv4_address }
}

output "mac_addresses" {
  description = "MAC address of every adapter of each VM (in slot order), keyed by name."
  value       = { for name, vm in virtualbox_vm.this : name => vm.network_adapter[*].mac_address }
}

output "primary_mac_addresses" {
  description = "MAC address of the primary adapter of each VM (lowercase, colon-separated, as the guest OS shows it), keyed by name."
  value = {
    for name, vm in virtualbox_vm.this : name => lower(join(":", regexall("[0-9A-Fa-f]{2}", vm.network_adapter[local.primary_adapter_index].mac_address)))
  }
}
