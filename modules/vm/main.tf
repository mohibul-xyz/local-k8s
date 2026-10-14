locals {
  names = var.instance_count == 1 ? [var.name] : [
    for i in range(var.instance_count) : format("%s-%02d", var.name, i + 1)
  ]

  # The NAT adapter's address (10.0.2.15) isn't reachable from the host, so
  # default to the first adapter that isn't NAT.
  primary_adapter_index = coalesce(
    var.primary_adapter_index,
    try(index([for a in var.network_adapters : a.type == "nat"], false), 0),
  )
}

resource "virtualbox_vm" "this" {
  for_each = toset(local.names)

  name          = each.key
  image         = can(regex("^https?://", var.image)) ? var.image : pathexpand(var.image)
  checksum      = var.image_checksum
  checksum_type = var.image_checksum_type
  cpus          = var.cpus
  memory        = "${var.memory_mb} mib"
  boot_order    = var.boot_order
  optical_disks = var.optical_disks
  user_data     = var.user_data
  status        = var.status

  dynamic "network_adapter" {
    for_each = var.network_adapters

    content {
      type           = network_adapter.value.type
      host_interface = network_adapter.value.host_interface
      device         = network_adapter.value.device
    }
  }

  lifecycle {
    precondition {
      condition     = local.primary_adapter_index >= 0 && local.primary_adapter_index < length(var.network_adapters)
      error_message = "primary_adapter_index must point at an entry in network_adapters."
    }

    precondition {
      condition     = (var.image_checksum == null) == (var.image_checksum_type == null)
      error_message = "image_checksum and image_checksum_type must be set together."
    }
  }
}
