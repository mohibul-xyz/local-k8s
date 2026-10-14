variable "cluster_name" {
  description = "Cluster name; prefixes every VM (\"<name>-cp-01\", \"<name>-worker-01\", ...). Lowercase letters, digits and '-'."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}[a-z0-9]$", var.cluster_name))
    error_message = "cluster_name must be 2-32 lowercase letters, digits or '-', starting with a letter and not ending with '-'."
  }
}

variable "image" {
  description = "Ubuntu Vagrant box (VirtualBox provider, with Guest Additions): a local .box path or an http(s) URL."
  type        = string
}

variable "network" {
  description = "Host-only network the nodes live on, with the host as gateway. See modules/fleet."
  type = object({
    cidr        = string
    gateway     = string
    dns_servers = optional(list(string), ["1.1.1.1", "8.8.8.8"])
  })
}

variable "host_only_interface" {
  description = "VirtualBox host-only network the nodes attach to."
  type        = string
  default     = "vboxnet0"
}

variable "first_host_number" {
  description = "Host number (in network.cidr) of the control plane. Workers take the following numbers: with 192.168.56.0/24 and 30, the control plane is .30 and workers .31, .32, ..."
  type        = number
  default     = 10

  validation {
    condition     = var.first_host_number >= 2 && floor(var.first_host_number) == var.first_host_number
    error_message = "first_host_number must be a whole number >= 2 (.1 is the host)."
  }
}

variable "max_host_number" {
  description = "Highest host number a node may use. Keeps nodes below the DHCP range (.100-.199 from scripts/vbox-network.sh)."
  type        = number
  default     = 99
}

variable "worker_count" {
  description = "Number of worker nodes. With the single control plane, the cluster has worker_count + 1 nodes."
  type        = number
  default     = 2

  validation {
    condition     = var.worker_count >= 2 && floor(var.worker_count) == var.worker_count
    error_message = "worker_count must be a whole number >= 2 (3 nodes minimum)."
  }
}

variable "control_plane" {
  description = "Control plane VM size. kubeadm needs at least 2 CPUs and ~1.7 GiB."
  type = object({
    cpus      = optional(number, 2)
    memory_mb = optional(number, 4096)
  })
  default = {}

  validation {
    condition     = var.control_plane.cpus >= 2 && var.control_plane.memory_mb >= 2048
    error_message = "The control plane needs at least 2 CPUs and 2048 MiB."
  }
}

variable "worker" {
  description = "Size of each worker VM."
  type = object({
    cpus      = optional(number, 2)
    memory_mb = optional(number, 4096)
  })
  default = {}

  validation {
    condition     = var.worker.cpus >= 1 && var.worker.memory_mb >= 1024
    error_message = "Workers need at least 1 CPU and 1024 MiB."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes minor version (\"1.37\"). The latest patch release of it is installed and held."
  type        = string
  default     = "1.37"

  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.kubernetes_version))
    error_message = "kubernetes_version is a minor version like \"1.37\"."
  }
}

variable "pod_cidr" {
  description = "Pod network. Must not overlap network.cidr or service_cidr."
  type        = string
  default     = "10.244.0.0/16"

  validation {
    condition     = can(cidrhost(var.pod_cidr, 0))
    error_message = "pod_cidr must be a valid CIDR."
  }
}

variable "service_cidr" {
  description = "Service (ClusterIP) network. Must not overlap network.cidr or pod_cidr."
  type        = string
  default     = "10.96.0.0/12"

  validation {
    condition     = can(cidrhost(var.service_cidr, 0))
    error_message = "service_cidr must be a valid CIDR."
  }
}

variable "flannel_version" {
  description = "Flannel (CNI) release tag."
  type        = string
  default     = "v0.28.10"
}

variable "kubeconfig_path" {
  description = "Where to write the cluster's admin kubeconfig. Defaults to <root module>/<cluster_name>.kubeconfig."
  type        = string
  default     = null
}

variable "inventory_path" {
  description = "Where to write the Ansible inventory. Defaults to <root module>/<cluster_name>-inventory.yml."
  type        = string
  default     = null
}

variable "ssh_user" {
  description = "User baked into the box that Ansible logs in as."
  type        = string
  default     = "vagrant"
}

variable "ssh_private_key_file" {
  description = "Private key that can log in as ssh_user on a fresh box."
  type        = string
}

variable "admin_public_key_file" {
  description = "Your public key; authorized for ssh_user on every node. Null skips it."
  type        = string
  default     = null
}
