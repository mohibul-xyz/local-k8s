variable "box_image" {
  description = "Ubuntu Vagrant box (VirtualBox provider, with Guest Additions): a local .box path or an http(s) URL."
  type        = string
}

variable "ssh_private_key_file" {
  description = "Private key a fresh box accepts (Vagrant's insecure key)."
  type        = string
}

variable "admin_public_key_file" {
  description = "Your public key, authorized on every node."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}
