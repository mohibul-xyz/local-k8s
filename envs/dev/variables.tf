variable "vms" {
  description = "VMs to create, keyed by name. Only ip is required; see modules/fleet for every field."
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
}

variable "box_image" {
  description = "Default Vagrant box (VirtualBox provider) for every VM: a local .box path or an http(s) URL."
  type        = string
}

variable "host_only_interface" {
  description = "Host-only network the VMs attach to. scripts/vbox-network.sh creates it."
  type        = string
  default     = "vboxnet0"
}

variable "network_cidr" {
  description = "Subnet of the host-only network. Keep fixed IPs out of the DHCP range (.100-.199 by default)."
  type        = string
  default     = "192.168.56.0/24"
}

variable "gateway_ip" {
  description = "Host's address on the host-only network; VMs route through it (scripts/host-nat.sh)."
  type        = string
  default     = "192.168.56.1"
}

variable "dns_servers" {
  description = "DNS resolvers for the VMs. Public resolvers keep working whatever network the host is on."
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}

variable "ssh_user" {
  description = "User baked into the box that Ansible logs in as."
  type        = string
  default     = "vagrant"
}

variable "ssh_private_key_file" {
  description = "Private key that can log in as ssh_user on a fresh box (for official Vagrant boxes, Vagrant's insecure key)."
  type        = string
}

variable "admin_public_key_file" {
  description = "Your public key. Ansible authorizes it for ssh_user, so you can SSH in with your own key."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "run_ansible" {
  description = "Run the Ansible playbook automatically after the VMs are up."
  type        = bool
  default     = true
}

variable "ip_wait_delay_seconds" {
  description = "Provider: seconds to wait after starting a VM before the first check for its IP. The provider's overall wait is fixed at 5 minutes, including this delay."
  type        = number
  default     = 30
}

variable "ip_wait_min_timeout_seconds" {
  description = "Provider: minimum seconds between checks for the VM's IP."
  type        = number
  default     = 5
}
