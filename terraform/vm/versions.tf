terraform {
  required_version = ">= 1.9" # validacije koje referenciraju druge varijable

  required_providers {
    # Serija 0.8 kao na vježbama (s2/p3): 0.9 ima drugačiju sintaksu resursa.
    libvirt = { source = "dmacvicar/libvirt", version = "~> 0.8.3" }
    tls     = { source = "hashicorp/tls", version = "~> 4.0" }
    local   = { source = "hashicorp/local", version = "~> 2.5" }
  }
}

provider "libvirt" {
  uri = var.libvirt_uri
}
