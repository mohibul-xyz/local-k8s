variable "name" {
  description = "VM name. When instance_count > 1, each VM is named \"<name>-01\", \"<name>-02\", ..."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._-]*$", var.name))
    error_message = "name must start with a letter or digit and contain only letters, digits, '.', '_' or '-'."
  }
}

variable "instance_count" {
  description = "Number of identical VMs to create."
  type        = number
  default     = 1

  validation {
    condition     = var.instance_count >= 1 && floor(var.instance_count) == var.instance_count
    error_message = "instance_count must be a whole number >= 1."
  }
}

variable "image" {
  description = "Vagrant box (VirtualBox provider) to build the VM from: a local path to a .box file or an http(s) URL."
  type        = string
}

variable "image_checksum" {
  description = "Optional checksum of the image, verified before use."
  type        = string
  default     = null
}

variable "image_checksum_type" {
  description = "Hash algorithm of image_checksum (e.g. \"sha256\", \"md5\"). Required when image_checksum is set."
  type        = string
  default     = null
}

variable "cpus" {
  description = "Number of virtual CPUs."
  type        = number
  default     = 2

  validation {
    condition     = var.cpus >= 1 && floor(var.cpus) == var.cpus
    error_message = "cpus must be a whole number >= 1."
  }
}

variable "memory_mb" {
  description = "Memory in MiB."
  type        = number
  default     = 2048

  validation {
    condition     = var.memory_mb >= 128 && floor(var.memory_mb) == var.memory_mb
    error_message = "memory_mb must be a whole number >= 128."
  }
}

variable "network_adapters" {
  description = <<-EOT
    Network adapters, in slot order (adapter 1 first, max 8).
    - type:           "nat", "bridged" or "hostonly".
    - host_interface: host NIC for "bridged" (e.g. "enp11s0") or host-only network for "hostonly" (e.g. "vboxnet0").
    - device:         emulated NIC: "IntelPro1000MTServer" (default), "IntelPro1000MTDesktop", "IntelPro1000TServer", "FASTIII" or "VirtIO".
  EOT
  type = list(object({
    type           = string
    host_interface = optional(string)
    device         = optional(string, "IntelPro1000MTServer")
  }))
  default = [{ type = "nat" }]

  validation {
    condition     = length(var.network_adapters) >= 1 && length(var.network_adapters) <= 8
    error_message = "Between 1 and 8 network adapters are supported."
  }

  validation {
    condition     = alltrue([for a in var.network_adapters : contains(["nat", "bridged", "hostonly"], a.type)])
    error_message = "network_adapters[*].type must be one of \"nat\", \"bridged\", \"hostonly\"."
  }

  validation {
    condition     = alltrue([for a in var.network_adapters : a.type == "nat" || a.host_interface != null])
    error_message = "\"bridged\" and \"hostonly\" adapters need host_interface set."
  }

  validation {
    condition = alltrue([for a in var.network_adapters : contains(
      ["IntelPro1000MTServer", "IntelPro1000MTDesktop", "IntelPro1000TServer", "FASTIII", "VirtIO"], a.device
    )])
    error_message = "network_adapters[*].device must be one of IntelPro1000MTServer, IntelPro1000MTDesktop, IntelPro1000TServer, FASTIII, VirtIO."
  }
}

variable "primary_adapter_index" {
  description = "Zero-based index into network_adapters whose IPv4 address is reported as primary_ipv4_addresses. Defaults to the first non-NAT adapter (NAT adapters always report the unreachable 10.0.2.15), or 0 if all are NAT."
  type        = number
  default     = null
}

variable "boot_order" {
  description = "Boot device order, up to 4 of \"none\", \"floppy\", \"dvd\", \"disk\", \"net\". Null keeps the image's default."
  type        = list(string)
  default     = null

  validation {
    condition = var.boot_order == null ? true : (
      length(var.boot_order) <= 4 &&
      alltrue([for d in var.boot_order : contains(["none", "floppy", "dvd", "disk", "net"], d)])
    )
    error_message = "boot_order takes at most 4 entries from \"none\", \"floppy\", \"dvd\", \"disk\", \"net\"."
  }
}

variable "optical_disks" {
  description = "Paths to ISO images to attach as optical drives."
  type        = list(string)
  default     = []
}

variable "user_data" {
  description = "Passed as-is to the provider's user_data attribute."
  type        = string
  default     = null
}

variable "status" {
  description = "Desired power state: \"running\" or \"poweroff\"."
  type        = string
  default     = "running"

  validation {
    condition     = contains(["running", "poweroff"], var.status)
    error_message = "status must be \"running\" or \"poweroff\"."
  }
}
