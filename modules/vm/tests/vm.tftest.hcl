mock_provider "virtualbox" {}

variables {
  name  = "node"
  image = "~/boxes/test.box"
}

run "single_vm_keeps_its_name" {
  command = plan

  assert {
    condition     = output.names == ["node"]
    error_message = "A single VM should be named exactly var.name."
  }

  assert {
    condition     = virtualbox_vm.this["node"].memory == "2048 mib"
    error_message = "memory_mb should be passed to the provider as \"<n> mib\"."
  }

  assert {
    condition     = !startswith(virtualbox_vm.this["node"].image, "~")
    error_message = "Local image paths should have ~ expanded."
  }
}

run "multiple_vms_get_numbered_names" {
  command = plan

  variables {
    instance_count = 3
  }

  assert {
    condition     = join(",", output.names) == "node-01,node-02,node-03"
    error_message = "Multiple VMs should be suffixed -01, -02, ..."
  }
}

run "primary_adapter_skips_nat" {
  variables {
    network_adapters = [
      { type = "nat" },
      { type = "hostonly", host_interface = "vboxnet0" },
    ]
  }

  assert {
    condition     = local.primary_adapter_index == 1
    error_message = "The first non-NAT adapter should be primary."
  }
}

run "hostonly_requires_interface" {
  command = plan

  variables {
    network_adapters = [{ type = "hostonly" }]
  }

  expect_failures = [var.network_adapters]
}
