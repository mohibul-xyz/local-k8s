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
}
