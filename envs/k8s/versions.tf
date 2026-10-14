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

  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "virtualbox" {
  # First IP check 30s after a VM starts, then every 5s; the provider's
  # total wait is fixed at 5 minutes.
  delay      = 30
  mintimeout = 5
}
