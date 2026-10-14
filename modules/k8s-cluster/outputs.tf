output "kubeconfig_path" {
  description = "Admin kubeconfig for the cluster. Written once provisioning finishes: `export KUBECONFIG=<this>`."
  value       = local.kubeconfig_path
  depends_on  = [module.fleet.ansible_run_id]
}

output "api_server_endpoint" {
  description = "Kubernetes API server URL."
  value       = "https://${local.nodes[local.control_plane_name].ip}:6443"
}

output "control_plane" {
  description = "Control plane node name and IP."
  value       = { (local.control_plane_name) = local.nodes[local.control_plane_name].ip }
}

output "workers" {
  description = "Worker node names and IPs."
  value       = { for name in local.worker_names : name => local.nodes[name].ip }
}

output "ssh_commands" {
  description = "SSH command for each node."
  value       = { for name, node in local.nodes : name => "ssh ${var.ssh_user}@${node.ip}" }
}

output "inventory_path" {
  description = "Generated Ansible inventory for the cluster."
  value       = local.inventory_path
}
