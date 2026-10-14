variable "network" {
  description = <<-EOT
    The network the VMs' fixed IPs live on — normally a host-only network
    whose gateway is the host itself (see scripts/host-nat.sh).
    - cidr:        e.g. "192.168.56.0/24".
    - gateway:     default route for the VMs, e.g. "192.168.56.1" (the host).
    - dns_servers: resolvers the VMs use.
  EOT
  type = object({
    cidr        = string
    gateway     = string
    dns_servers = optional(list(string), ["1.1.1.1", "8.8.8.8"])
  })

  validation {
    condition     = can(cidrhost(var.network.cidr, 0)) && can(cidrhost("${var.network.gateway}/32", 0))
    error_message = "network.cidr must be a valid CIDR and network.gateway a valid IPv4 address."
  }
}

variable "vms" {
  description = <<-EOT
    VMs to create, keyed by VM name (also used as the Ansible inventory hostname).
    - ip:               Fixed IPv4 address inside network.cidr. Ansible configures it in the guest.
    - image:            Vagrant box path/URL. Defaults to var.default_image.
    - cpus, memory_mb:  Sizing.
    - network_adapters: Defaults to var.default_network_adapters. See modules/vm for the schema.
    - groups:           Ansible groups the VM joins (e.g. ["web"]).
    - packages:         Extra OS packages Ansible installs on this VM (host var "extra_packages").
    - host_vars:        Any other Ansible host vars, as strings.
    - status:           "running" or "poweroff".
  EOT
  type = map(object({
    ip        = string
    image     = optional(string)
    cpus      = optional(number, 2)
    memory_mb = optional(number, 2048)
    network_adapters = optional(list(object({
      type           = string
      host_interface = optional(string)
      device         = optional(string, "IntelPro1000MTServer")
    })))
    groups    = optional(list(string), [])
    packages  = optional(list(string), [])
    host_vars = optional(map(string), {})
    status    = optional(string, "running")
  }))

  validation {
    condition     = length(var.vms) > 0
    error_message = "Define at least one VM."
  }

  validation {
    condition = alltrue([
      for vm in values(var.vms) : try(
        cidrhost("${vm.ip}/${split("/", var.network.cidr)[1]}", 0) == cidrhost(var.network.cidr, 0),
        false,
      )
    ])
    error_message = "Every VM's ip must be a valid IPv4 address inside network.cidr."
  }

  validation {
    condition     = length(distinct([for vm in values(var.vms) : vm.ip])) == length(var.vms)
    error_message = "Two VMs share the same ip."
  }

  validation {
    condition     = !contains([for vm in values(var.vms) : vm.ip], var.network.gateway)
    error_message = "A VM's ip can't be the gateway (host) address."
  }

  validation {
    condition = alltrue(flatten([
      for vm in values(var.vms) : [for g in vm.groups : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", g))]
    ]))
    error_message = "Ansible group names may only contain letters, digits and '_', and can't start with a digit."
  }
}

variable "default_image" {
  description = "Vagrant box path/URL used by VMs that don't set image."
  type        = string
  default     = null
}

variable "default_network_adapters" {
  description = "Network adapters for VMs that don't set network_adapters. The fixed IP goes on the primary adapter (first non-NAT one)."
  type = list(object({
    type           = string
    host_interface = optional(string)
    device         = optional(string, "IntelPro1000MTServer")
  }))
  default = [{ type = "hostonly", host_interface = "vboxnet0" }]
}

variable "inventory_path" {
  description = "Where to write the generated Ansible inventory (YAML). Null skips writing it."
  type        = string
  default     = null
}

variable "ansible_user" {
  description = "SSH user Ansible connects as. Vagrant boxes ship with \"vagrant\"."
  type        = string
  default     = "vagrant"
}

variable "ansible_ssh_private_key_file" {
  description = "Private key Ansible uses to log in as ansible_user."
  type        = string
  default     = null
}

variable "ansible_vars" {
  description = "Extra variables placed under all.vars in the inventory."
  type        = map(string)
  default     = {}
}

variable "ansible_playbook" {
  description = "Playbook to run against the VMs once they're up (absolute path; its directory must hold ansible.cfg). Null skips running Ansible. Needs inventory_path."
  type        = string
  default     = null
}
