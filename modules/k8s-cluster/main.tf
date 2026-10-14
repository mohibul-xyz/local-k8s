locals {
  control_plane_name = "${var.cluster_name}-cp-01"
  worker_names       = [for i in range(var.worker_count) : format("%s-worker-%02d", var.cluster_name, i + 1)]

  last_host_number = var.first_host_number + var.worker_count

  nodes = merge(
    {
      (local.control_plane_name) = {
        ip        = cidrhost(var.network.cidr, var.first_host_number)
        cpus      = var.control_plane.cpus
        memory_mb = var.control_plane.memory_mb
        groups    = ["k8s_control_plane"]
      }
    },
    {
      for i, name in local.worker_names : name => {
        ip        = cidrhost(var.network.cidr, var.first_host_number + i + 1)
        cpus      = var.worker.cpus
        memory_mb = var.worker.memory_mb
        groups    = ["k8s_workers"]
      }
    },
  )

  # Two CIDRs overlap when they share a network address at the shorter prefix.
  cidrs = [
    { name = "network.cidr", cidr = var.network.cidr },
    { name = "pod_cidr", cidr = var.pod_cidr },
    { name = "service_cidr", cidr = var.service_cidr },
  ]
  overlapping = [
    for pair in [[0, 1], [0, 2], [1, 2]] : "${local.cidrs[pair[0]].name} and ${local.cidrs[pair[1]].name}"
    if cidrhost("${cidrhost(local.cidrs[pair[0]].cidr, 0)}/${min([for i in pair : tonumber(split("/", local.cidrs[i].cidr)[1])]...)}", 0)
    == cidrhost("${cidrhost(local.cidrs[pair[1]].cidr, 0)}/${min([for i in pair : tonumber(split("/", local.cidrs[i].cidr)[1])]...)}", 0)
  ]

  kubeconfig_path = abspath(coalesce(var.kubeconfig_path, "${path.root}/${var.cluster_name}.kubeconfig"))
  inventory_path  = abspath(coalesce(var.inventory_path, "${path.root}/${var.cluster_name}-inventory.yml"))
  ansible_dir     = abspath("${path.module}/../../ansible")

  ansible_vars = merge(
    {
      kubernetes_version  = var.kubernetes_version
      k8s_pod_cidr        = var.pod_cidr
      k8s_service_cidr    = var.service_cidr
      k8s_flannel_version = var.flannel_version
      k8s_kubeconfig_dest = local.kubeconfig_path
    },
    var.admin_public_key_file == null ? {} : { admin_public_key_file = pathexpand(var.admin_public_key_file) },
  )
}

resource "terraform_data" "checks" {
  input = local.nodes

  lifecycle {
    precondition {
      condition     = length(local.overlapping) == 0
      error_message = "These networks overlap: ${join(", ", local.overlapping)}. Change pod_cidr/service_cidr."
    }

    precondition {
      condition     = local.last_host_number <= var.max_host_number && local.last_host_number < pow(2, 32 - tonumber(split("/", var.network.cidr)[1])) - 1
      error_message = "Nodes would run up to host number ${local.last_host_number}, past max_host_number (${var.max_host_number}) or the end of ${var.network.cidr}. Lower first_host_number or worker_count."
    }
  }
}

module "fleet" {
  source = "../fleet"

  vms           = local.nodes
  default_image = var.image
  network       = var.network

  default_network_adapters = [
    { type = "hostonly", host_interface = var.host_only_interface },
  ]

  inventory_path               = local.inventory_path
  ansible_playbook             = "${local.ansible_dir}/k8s.yml"
  ansible_user                 = var.ssh_user
  ansible_ssh_private_key_file = pathexpand(var.ssh_private_key_file)
  ansible_vars                 = local.ansible_vars

  depends_on = [terraform_data.checks]
}

# Removes the fetched kubeconfig when the cluster is destroyed.
resource "terraform_data" "kubeconfig" {
  input = local.kubeconfig_path

  provisioner "local-exec" {
    when    = destroy
    command = "rm -f '${self.input}'"
  }

  depends_on = [module.fleet]
}
