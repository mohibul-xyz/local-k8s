locals {
  ansible_dir    = abspath("${path.root}/../../ansible")
  inventory_path = abspath("${path.root}/inventory.yml")
}

module "fleet" {
  source = "../../modules/fleet"

  vms           = var.vms
  default_image = var.box_image

  # One adapter on the host-only network. The VM boots on DHCP, Ansible pins
  # its fixed IP, and all outbound traffic is routed through the host
  # (gateway_ip), which NATs it out of whatever uplink the host is using.
  default_network_adapters = [
    { type = "hostonly", host_interface = var.host_only_interface },
  ]

  network = {
    cidr        = var.network_cidr
    gateway     = var.gateway_ip
    dns_servers = var.dns_servers
  }

  inventory_path               = local.inventory_path
  ansible_user                 = var.ssh_user
  ansible_ssh_private_key_file = pathexpand(var.ssh_private_key_file)
  ansible_vars = {
    admin_public_key_file = pathexpand(var.admin_public_key_file)
  }
  ansible_playbook = var.run_ansible ? "${local.ansible_dir}/site.yml" : null
}