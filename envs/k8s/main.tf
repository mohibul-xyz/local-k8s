module "k8s" {
  source = "../../modules/k8s-cluster"

  cluster_name = "lab"
  worker_count = 2 # 1 control plane + 2 workers
  image        = var.box_image

  # Nodes get 192.168.56.30 (control plane), .31, .32, ...
  # Keep clear of other environments on the same network (envs/dev).
  first_host_number = 30
  network = {
    cidr    = "192.168.56.0/24"
    gateway = "192.168.56.1"
  }

  control_plane = { cpus = 2, memory_mb = 4096 }
  worker        = { cpus = 2, memory_mb = 4096 }

  kubernetes_version = "1.37"

  ssh_private_key_file  = var.ssh_private_key_file
  admin_public_key_file = var.admin_public_key_file
}

output "kubeconfig" {
  value = "export KUBECONFIG=${module.k8s.kubeconfig_path}"
}

output "api_server_endpoint" {
  value = module.k8s.api_server_endpoint
}

output "nodes" {
  value = merge(module.k8s.control_plane, module.k8s.workers)
}
