mock_provider "virtualbox" {}
mock_provider "local" {}

variables {
  default_image = "/tmp/test.box"
  network = {
    cidr    = "192.168.56.0/24"
    gateway = "192.168.56.1"
  }
  vms = {
    web-01 = { ip = "192.168.56.11", groups = ["web"], packages = ["htop"] }
    web-02 = { ip = "192.168.56.12", groups = ["web"] }
    db-01  = { ip = "192.168.56.21", groups = ["db"], memory_mb = 4096, host_vars = { timezone = "UTC" } }
  }
}

run "inventory_groups_and_host_vars" {
  assert {
    condition     = keys(yamldecode(output.inventory).all.children.web.hosts) == ["web-01", "web-02"]
    error_message = "web group should contain both web VMs."
  }

  assert {
    condition     = yamldecode(output.inventory).all.hosts["web-01"].extra_packages == ["htop"]
    error_message = "packages should become the extra_packages host var."
  }

  assert {
    condition     = yamldecode(output.inventory).all.hosts["db-01"].timezone == "UTC"
    error_message = "host_vars should be copied into the inventory."
  }

  assert {
    condition     = yamldecode(output.inventory).all.hosts["db-01"].static_ip == "192.168.56.21"
    error_message = "ip should become the static_ip host var."
  }

  assert {
    condition     = yamldecode(output.inventory).all.vars.static_network_prefix == 24 && yamldecode(output.inventory).all.vars.static_network_gateway == "192.168.56.1"
    error_message = "Network prefix and gateway should be in all.vars."
  }

  assert {
    condition     = output.ip_addresses["web-02"] == "192.168.56.12"
    error_message = "ip_addresses should report the fixed IPs."
  }
}

run "rejects_bad_group_names" {
  command = plan

  variables {
    vms = { a = { ip = "192.168.56.10", groups = ["web-servers"] } }
  }

  expect_failures = [var.vms]
}

run "rejects_ip_outside_network" {
  command = plan

  variables {
    vms = { a = { ip = "10.0.0.5" } }
  }

  expect_failures = [var.vms]
}

run "rejects_duplicate_ips" {
  command = plan

  variables {
    vms = {
      a = { ip = "192.168.56.10" }
      b = { ip = "192.168.56.10" }
    }
  }

  expect_failures = [var.vms]
}

run "rejects_gateway_ip" {
  command = plan

  variables {
    vms = { a = { ip = "192.168.56.1" } }
  }

  expect_failures = [var.vms]
}
