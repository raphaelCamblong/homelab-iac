# Versions pinned 2026-05-15 — latest stable at authoring time.
#   siderolabs/talos          0.11.0
#   hashicorp/local            2.9.0
#   carlpett/sops              1.4.1
#   hashicorp/kubernetes       3.1.0  (major bump from 2.x; resource schemas may differ)
#   fluxcd/flux                1.8.7
#   integrations/github        6.12.1
#   hashicorp/tls              4.3.0
terraform {
  required_version = ">= 1.6"
  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.11"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.4"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.1"
    }
    flux = {
      source  = "fluxcd/flux"
      version = "~> 1.8"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.12"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.3"
    }
    # Pre-Flux Cilium install (breaks the CNI/Flux bootstrap chicken-and-egg).
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
  }
}
