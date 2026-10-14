mock_provider "virtualbox" {}
mock_provider "local" {}

variables {
  cluster_name         = "lab"
  image                = "/tmp/test.box"
  ssh_private_key_file = "/tmp/key"
  network = {
    cidr    = "192.168.56.0/24"
    gateway = "192.168.56.1"
  }
}

run "three_nodes_by_default" {
  command = plan

  assert {
    condition     = output.control_plane == { "lab-cp-01" = "192.168.56.10" }
    error_message = "Control plane should take first_host_number."
  }

  assert {
    condition     = output.workers == { "lab-worker-01" = "192.168.56.11", "lab-worker-02" = "192.168.56.12" }
    error_message = "Workers should take the following host numbers."
  }

  assert {
    condition     = output.api_server_endpoint == "https://192.168.56.10:6443"
    error_message = "API endpoint should be the control plane IP."
  }
}

run "nodes_groups_and_ansible_vars" {
  command = plan

  variables {
    worker_count      = 3
    first_host_number = 30
  }

  assert {
    condition     = length([for n in values(local.nodes) : n if contains(n.groups, "k8s_workers")]) == 3
    error_message = "All workers should be in k8s_workers."
  }

  assert {
    condition     = local.nodes["lab-worker-03"].ip == "192.168.56.33"
    error_message = "Worker IPs should follow first_host_number."
  }

  assert {
    condition     = local.ansible_vars.kubernetes_version == "1.37" && local.ansible_vars.k8s_pod_cidr == "10.244.0.0/16"
    error_message = "Cluster settings should reach Ansible."
  }
}

run "rejects_fewer_than_two_workers" {
  command = plan

  variables {
    worker_count = 1
  }

  expect_failures = [var.worker_count]
}

run "rejects_overlapping_pod_cidr" {
  command = plan

  variables {
    pod_cidr = "192.168.0.0/16"
  }

  expect_failures = [terraform_data.checks]
}

run "rejects_nodes_in_dhcp_range" {
  command = plan

  variables {
    first_host_number = 98
  }

  expect_failures = [terraform_data.checks]
}

run "rejects_small_control_plane" {
  command = plan

  variables {
    control_plane = { cpus = 1 }
  }

  expect_failures = [var.control_plane]
}
