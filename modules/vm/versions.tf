terraform {
  required_version = ">= 1.5"

  required_providers {
    virtualbox = {
      source  = "shekeriev/virtualbox"
      version = "~> 0.0.4"
    }
  }
}
