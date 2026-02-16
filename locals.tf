locals {
  cluster_loadbalancer_running = length(data.hcloud_load_balancers.rke2_control_plane.load_balancers) > 0
  cluster_ca                   = data.remote_file.kubeconfig.content == "" ? "" : base64decode(yamldecode(data.remote_file.kubeconfig.content).clusters[0].cluster.certificate-authority-data)
  client_key                   = data.remote_file.kubeconfig.content == "" ? "" : base64decode(yamldecode(data.remote_file.kubeconfig.content).users[0].user.client-key-data)
  client_cert                  = data.remote_file.kubeconfig.content == "" ? "" : base64decode(yamldecode(data.remote_file.kubeconfig.content).users[0].user.client-certificate-data)
  cluster_host                 = "https://${hcloud_load_balancer.control_plane.ipv4}:6443"
  kube_config                  = replace(data.remote_file.kubeconfig.content, "https://127.0.0.1:6443", local.cluster_host)

  is_ha_cluster = var.master_node_count >= 3

  system_upgrade_controller_crds       = try(split("---", data.http.system_upgrade_controller_crds[0].response_body), null)
  system_upgrade_controller_components = try(split("---", data.http.system_upgrade_controller[0].response_body), null)

  # DECISION: Auto-detect Hetzner Object Storage endpoint from lb_location.
  # Why: Reduces configuration burden — operator only needs bucket + credentials.
  # Hetzner endpoints follow pattern: {location}.your-objectstorage.com.
  # See: https://docs.hetzner.com/storage/object-storage/overview
  etcd_s3_endpoint = (
    trimspace(var.cluster_configuration.etcd_backup.s3_endpoint) != ""
    ? var.cluster_configuration.etcd_backup.s3_endpoint
    : "${var.lb_location}.your-objectstorage.com"
  )

  etcd_s3_folder = (
    trimspace(var.cluster_configuration.etcd_backup.s3_folder) != ""
    ? var.cluster_configuration.etcd_backup.s3_folder
    : var.cluster_name
  )
}
