# Generate the base controlplane config with cluster-wide + controlplane patches.
data "talos_machine_configuration" "controlplane" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = local.talos_machine_secrets
  kubernetes_version = var.kubernetes_version
  config_patches = [
    file("${path.module}/../talos/patches/cluster.yaml"),
    file("${path.module}/../talos/patches/controlplane.yaml"),
  ]
}

# Per-node apply. The node-specific hostname patch is layered on top.
resource "talos_machine_configuration_apply" "controlplane" {
  count = length(var.node_ips)

  client_configuration        = local.talos_client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = var.node_ips[count.index]

  config_patches = [
    file("${path.module}/../talos/patches/node-${var.node_hostnames[count.index]}.yaml"),
  ]
}
