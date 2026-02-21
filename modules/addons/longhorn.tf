# ──────────────────────────────────────────────────────────────────────────────
# Longhorn — distributed block storage with native backup
# https://longhorn.io/
#
# DECISION: Longhorn as primary storage driver with native backup
# Why: Integrated storage + backup in single component. Fewer components
#      in restore path. Native VolumeSnapshot (Hetzner CSI has none —
#      issue #849). Instant pre-upgrade snapshots.
#
# DECISION: Longhorn replaces Hetzner CSI as primary storage driver
# Why: Replication across workers (HA). Local NVMe IOPS (~50K vs ~10K).
#      VolumeSnapshot support. Native S3 backup.
#
# NOTE: Longhorn is marked EXPERIMENTAL. Hetzner CSI retained as fallback.
# TODO: Promote Longhorn to default after battle-tested in production.
# ──────────────────────────────────────────────────────────────────────────────

# NOTE: All check {} blocks go to root guardrails.tf (not here).
# This follows the existing codebase pattern where all cross-variable
# consistency checks are centralized in guardrails.tf.
# See: Step 2f of PLAN-operational-readiness.md for the guardrail definitions.

# --- Namespace ---

resource "kubernetes_namespace_v1" "longhorn" {
  depends_on = [terraform_data.wait_for_infrastructure]
  count      = var.cluster_configuration.longhorn.preinstall ? 1 : 0
  metadata {
    name = "longhorn-system"
  }
  lifecycle {
    ignore_changes = [metadata[0].annotations, metadata[0].labels]
  }
}

# --- S3 Credentials Secret ---

# DECISION: Separate S3 credentials for Longhorn (independent from etcd_backup).
# Why: Module's self-contained addon pattern. Each addon owns its config.
#      Operators can share credentials at the module invocation level.
resource "kubernetes_secret_v1" "longhorn_s3" {
  depends_on = [kubernetes_namespace_v1.longhorn]
  count = (
    var.cluster_configuration.longhorn.preinstall &&
    trimspace(var.cluster_configuration.longhorn.backup_target) != ""
  ) ? 1 : 0

  metadata {
    name      = "longhorn-s3-credentials"
    namespace = "longhorn-system"
  }

  data = {
    AWS_ACCESS_KEY_ID     = var.cluster_configuration.longhorn.s3_access_key
    AWS_SECRET_ACCESS_KEY = var.cluster_configuration.longhorn.s3_secret_key
    AWS_ENDPOINTS         = local.longhorn_s3_endpoint
  }
}

# --- iSCSI Prerequisites (DaemonSet) ---

# DECISION: Install open-iscsi via Kubernetes DaemonSet instead of cloud-init.
# Why: Keeps cloud-init scripts minimal and Longhorn-agnostic. All Longhorn
#      prerequisites are managed by this file, following the addon pattern.
#      Uses Longhorn's official approach: nsenter into host mount namespace.
# See: https://longhorn.io/docs/latest/deploy/install/#installing-open-iscsi
resource "kubectl_manifest" "longhorn_iscsi_installer" {
  count      = var.cluster_configuration.longhorn.preinstall ? 1 : 0
  depends_on = [kubernetes_namespace_v1.longhorn, kubernetes_labels.longhorn_worker]

  yaml_body = <<-YAML
    apiVersion: apps/v1
    kind: DaemonSet
    metadata:
      name: longhorn-iscsi-installation
      namespace: longhorn-system
      labels:
        app: longhorn-iscsi-installation
    spec:
      selector:
        matchLabels:
          app: longhorn-iscsi-installation
      template:
        metadata:
          labels:
            app: longhorn-iscsi-installation
        spec:
          hostNetwork: true
          hostPID: true
          nodeSelector:
            node-role.kubernetes.io/worker: "true"
          initContainers:
          - name: iscsi-installation
            command:
            - nsenter
            - --mount=/proc/1/ns/mnt
            - --
            - bash
            - -c
            - |
              if ! systemctl is-active --quiet iscsid 2>/dev/null; then
                apt-get update -q -y && apt-get install -q -y open-iscsi
                systemctl enable iscsid
                systemctl start iscsid
              fi
              echo "iSCSI is ready"
            image: alpine:3.17
            securityContext:
              privileged: true
          containers:
          - name: sleep
            command:
            - /bin/sh
            - -c
            - sleep infinity
            image: registry.k8s.io/pause:3.9
  YAML
}

# --- Worker Node Labels ---

# DECISION: Declarative kubernetes_labels instead of SSH kubectl provisioner.
# Why: Idempotent, no SSH access needed, standard Terraform lifecycle.
#      RKE2 does NOT auto-label workers (only masters get role labels).
# NOTE: The label "node-role.kubernetes.io/worker=true" is used by Longhorn's
#       systemManagedComponentsNodeSelector to schedule data replicas only on workers,
#       protecting master disk space and etcd performance.
resource "kubernetes_labels" "longhorn_worker" {
  count = var.cluster_configuration.longhorn.preinstall ? var.worker_node_count : 0

  depends_on = [
    terraform_data.wait_for_infrastructure,
    helm_release.hcloud_ccm,
  ]

  api_version = "v1"
  kind        = "Node"

  metadata {
    name = var.worker_node_names[count.index]
  }

  labels = {
    "node-role.kubernetes.io/worker" = "true"
  }
}

# --- Helm Release ---

resource "helm_release" "longhorn" {
  depends_on = [
    kubernetes_namespace_v1.longhorn,
    kubernetes_labels.longhorn_worker,
    kubectl_manifest.longhorn_iscsi_installer,
    helm_release.hcloud_ccm,
    terraform_data.wait_for_infrastructure,
  ]
  count = var.cluster_configuration.longhorn.preinstall ? 1 : 0

  repository = "https://charts.longhorn.io"
  chart      = "longhorn"
  name       = "longhorn"
  namespace  = "longhorn-system"
  version    = var.cluster_configuration.longhorn.version
  timeout    = 600

  values = [templatefile("${path.module}/templates/values/longhorn.yaml", {
    REPLICA_COUNT                   = var.cluster_configuration.longhorn.replica_count
    DEFAULT_STORAGE_CLASS           = var.cluster_configuration.longhorn.default_storage_class
    BACKUP_TARGET                   = local.longhorn_backup_target
    BACKUP_TARGET_CREDENTIAL_SECRET = trimspace(var.cluster_configuration.longhorn.backup_target) != "" ? "longhorn-s3-credentials" : ""
    BACKUP_SCHEDULE                 = var.cluster_configuration.longhorn.backup_schedule
    BACKUP_RETAIN                   = var.cluster_configuration.longhorn.backup_retain
    GUARANTEED_INSTANCE_MANAGER_CPU = var.cluster_configuration.longhorn.guaranteed_instance_manager_cpu
    STORAGE_OVER_PROVISIONING       = var.cluster_configuration.longhorn.storage_over_provisioning
    STORAGE_MINIMAL_AVAILABLE       = var.cluster_configuration.longhorn.storage_minimal_available
    SNAPSHOT_MAX_COUNT              = var.cluster_configuration.longhorn.snapshot_max_count
  })]
}

# --- Longhorn Health Check ---

# DECISION: Separate health check for Longhorn, independent of the main cluster health check.
# Why: Follows the addon pattern — each addon manages its own lifecycle and validation.
#      Runs after Longhorn deployment to verify volumes are healthy.
resource "terraform_data" "longhorn_health_check" {
  count      = var.cluster_configuration.longhorn.preinstall ? 1 : 0
  depends_on = [helm_release.longhorn]

  triggers_replace = [var.rke2_version, var.cluster_configuration.longhorn.version]

  connection {
    type        = "ssh"
    host        = var.master_ipv4
    user        = "root"
    private_key = var.ssh_private_key
    timeout     = "5m"
  }

  # DECISION: Inline remote-exec instead of file provisioner.
  # Why: Eliminates /tmp/ file upload anti-pattern. Keeps all logic visible
  #      in Terraform config. No leftover scripts on remote nodes.
  provisioner "remote-exec" {
    inline = [
      "export KUBECONFIG=/etc/rancher/rke2/rke2.yaml",
      "export PATH=\"$$PATH:/var/lib/rancher/rke2/bin\"",
      "echo '=== Longhorn Health Check ===' ",
      "LH_COUNT=$(kubectl get pods -n longhorn-system --no-headers 2>/dev/null | grep -c Running || true)",
      "if [ \"$LH_COUNT\" -gt 0 ]; then DEGRADED=$(kubectl get volumes.longhorn.io -n longhorn-system -o jsonpath='{.items[?(@.status.robustness!=\"healthy\")].metadata.name}' 2>/dev/null || true); if [ -n \"$DEGRADED\" ]; then echo \"WARN: Longhorn degraded volumes: $DEGRADED\"; else echo 'PASS: Longhorn all volumes healthy'; fi; else echo 'INFO: No Longhorn volumes found (expected on fresh cluster)'; fi",
    ]
  }
}

# --- Longhorn Pre-upgrade Snapshot ---

# DECISION: Separate pre-upgrade snapshot for Longhorn volumes.
# Why: Follows the addon pattern. Creates instant COW snapshots before RKE2
#      version changes, providing a rollback point independent of etcd backup.
# NOTE: Longhorn snapshots are instant (copy-on-write) — no disk I/O.
resource "terraform_data" "longhorn_pre_upgrade_snapshot" {
  count      = var.cluster_configuration.longhorn.preinstall ? 1 : 0
  depends_on = [helm_release.longhorn]

  triggers_replace = [var.rke2_version]

  connection {
    type        = "ssh"
    host        = var.master_ipv4
    user        = "root"
    private_key = var.ssh_private_key
    timeout     = "5m"
  }

  # DECISION: Inline remote-exec instead of file provisioner.
  # Why: Eliminates /tmp/ file upload anti-pattern. No leftover scripts on nodes.
  provisioner "remote-exec" {
    inline = [
      "export KUBECONFIG=/etc/rancher/rke2/rke2.yaml",
      "export PATH=\"$$PATH:/var/lib/rancher/rke2/bin\"",
      "echo 'Creating Longhorn pre-upgrade snapshots...'",
      "TS=$(date +%s)",
      "for VOL in $(kubectl get volumes.longhorn.io -n longhorn-system -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do echo \"  Snapshotting: $VOL\"; kubectl -n longhorn-system apply -f - <<SNAP\napiVersion: longhorn.io/v1beta2\nkind: Snapshot\nmetadata:\n  name: pre-upgrade-$${VOL}-$${TS}\n  namespace: longhorn-system\nspec:\n  volume: $$VOL\n  labels:\n    pre-upgrade: \"true\"\nSNAP\n; done",
      "echo 'DONE: Longhorn snapshots created (instant, COW)'",
    ]
  }
}
