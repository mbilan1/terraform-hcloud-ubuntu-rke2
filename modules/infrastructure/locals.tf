# ──────────────────────────────────────────────────────────────────────────────
# Infrastructure module — computed locals
#
# NOTE: Only infrastructure-related locals live here.
# L4 addon configuration (Helm values, chart versions) lives in charts/
# and is managed via Helmfile/ArgoCD, not Terraform.
# ──────────────────────────────────────────────────────────────────────────────

locals {
  # --- Kubeconfig parsing ---
  # DECISION: Decode kubeconfig via try() + lookup() for resilient parsing.
  # Why: During initial plan (before any apply), kubeconfig content is empty.
  #      Using try() with fallback avoids errors for every parsed field without
  #      repeating the `== "" ? "" :` guard on each line. The intermediate
  #      `parsed_kubeconfig` local captures the YAML once and subsequent lookups
  #      navigate the parsed structure safely.
  # DECISION: Decode base64 kubeconfig from data "external" result.
  # Why: The fetch script base64-encodes the YAML to survive JSON transport.
  #      We decode it here once and all downstream locals parse the result.
  raw_kubeconfig    = try(base64decode(data.external.kubeconfig.result.kubeconfig_b64), "")
  parsed_kubeconfig = try(yamldecode(local.raw_kubeconfig), {})

  cluster_ca = try(
    base64decode(local.parsed_kubeconfig.clusters[0].cluster["certificate-authority-data"]),
    ""
  )
  client_cert = try(
    base64decode(local.parsed_kubeconfig.users[0].user["client-certificate-data"]),
    ""
  )
  client_key = try(
    base64decode(local.parsed_kubeconfig.users[0].user["client-key-data"]),
    ""
  )

  # Rewrite 127.0.0.1 → LB IP so the kubeconfig works from outside the cluster.
  cluster_host = "https://${hcloud_load_balancer.control_plane.ipv4}:6443"
  kube_config  = replace(local.raw_kubeconfig, "https://127.0.0.1:6443", local.cluster_host)

  # --- HA detection ---
  is_ha_cluster = var.control_plane_count >= 3

  # --- etcd S3 backup endpoint auto-detection ---
  # DECISION: Auto-detect Hetzner Object Storage endpoint from load_balancer_location.
  # Why: Reduces configuration burden — operator only needs bucket + credentials.
  # Hetzner endpoints follow pattern: {location}.your-objectstorage.com.
  # See: https://docs.hetzner.com/storage/object-storage/overview
  etcd_s3_endpoint = coalesce(
    trimspace(var.etcd_backup.s3_endpoint),
    "${var.load_balancer_location}.your-objectstorage.com"
  )

  etcd_s3_folder = coalesce(
    trimspace(var.etcd_backup.s3_folder),
    var.rke2_cluster_name
  )
}
