terraform {
  required_version = ">= 1.9"

  required_providers {
    virtualbox = {
      source  = "shekeriev/virtualbox"
      version = "~> 0.0.4"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }

  # VirtualBox is local to this machine, so local state is the natural fit.
  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "virtualbox" {
  # After starting a VM the provider waits `delay` seconds, then checks every
  # `mintimeout` seconds for the IP Guest Additions reports. It gives up after
  # a fixed 5 minutes in total.
  delay      = var.ip_wait_delay_seconds
  mintimeout = var.ip_wait_min_timeout_seconds
}
