variable "cluster_name" {
  type        = string
  description = "Cluster name."
  default     = "homelab"
}

variable "cluster_endpoint" {
  type        = string
  description = "Cluster API endpoint (the Talos VIP)."
  default     = "https://192.168.1.140:6443"
}

variable "kubernetes_version" {
  type        = string
  description = "Kubernetes version Talos will install. Default matches what Talos v1.13.2 ships with."
  default     = "1.36.0"
}

variable "talos_version" {
  type        = string
  description = "Talos minor version used in the factory image URL."
  default     = "v1.13"
}

variable "node_ips" {
  type        = list(string)
  description = "Static IPs of the 3 CM5 nodes."
  default     = ["192.168.1.51", "192.168.1.52", "192.168.1.53"]
}

variable "node_hostnames" {
  type        = list(string)
  description = "Hostnames; order must match node_ips."
  default     = ["cm5-1", "cm5-2", "cm5-3"]
}

variable "github_owner" {
  type        = string
  description = "GitHub user or org owning the cluster repo."
}

variable "github_token" {
  type        = string
  description = "PAT with repo + admin:public_key. Set via TF_VAR_github_token."
  sensitive   = true
}

variable "github_repo" {
  type    = string
  default = "homelab-iac"
}

variable "github_branch" {
  type    = string
  default = "main"
}

variable "flux_path" {
  type        = string
  description = "Path inside the repo Flux will sync."
  default     = "clusters/homelab"
}

variable "age_key_path" {
  type        = string
  description = "Path to the age private key file on the workstation."
  default     = "~/.config/sops/age/keys.txt"
}
