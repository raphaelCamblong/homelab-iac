resource "talos_machine_bootstrap" "this" {
  depends_on = [talos_machine_configuration_apply.controlplane]

  client_configuration = local.talos_client_configuration
  node                 = var.node_ips[0]
}

# Block apply until all CP nodes are Ready + etcd quorum is healthy.
# Without this, downstream resources (kubeconfig write, Flux bootstrap)
# can race the API and fail with transient connection errors.
data "talos_cluster_health" "this" {
  depends_on = [talos_machine_bootstrap.this]

  client_configuration = local.talos_client_configuration
  endpoints            = var.node_ips
  control_plane_nodes  = var.node_ips
}

data "talos_cluster_kubeconfig" "this" {
  depends_on = [data.talos_cluster_health.this]

  client_configuration = local.talos_client_configuration
  node                 = var.node_ips[0]
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = local.talos_client_configuration
  endpoints            = var.node_ips
  nodes                = var.node_ips
}

resource "local_sensitive_file" "kubeconfig" {
  content         = data.talos_cluster_kubeconfig.this.kubeconfig_raw
  filename        = pathexpand("~/.kube/configs/${var.cluster_name}")
  file_permission = "0600"
}

resource "local_sensitive_file" "talosconfig" {
  content         = data.talos_client_configuration.this.talos_config
  filename        = "${path.module}/talosconfig"
  file_permission = "0600"
}
