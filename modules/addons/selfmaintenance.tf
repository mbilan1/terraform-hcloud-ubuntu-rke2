# ──────────────────────────────────────────────────────────────────────────────
# Cluster self-maintenance — OS patching (Kured) + K8s upgrades (SUC)
#
# DECISION: Self-maintenance is gated on HA (≥3 masters).
# Why: Automated reboots and rolling upgrades require a quorum-safe control
#      plane. With a single master, a reboot = total cluster downtime.
#      The guard is enforced below via local.enable_* flags.
# ──────────────────────────────────────────────────────────────────────────────

locals {
  # Gate self-maintenance features on HA topology
  enable_os_patching  = var.enable_auto_os_updates && local.is_ha_cluster
  enable_k8s_upgrades = var.enable_auto_kubernetes_updates && local.is_ha_cluster

  # Combined gate for SUC resources that also require remote manifest access
  enable_suc_download = local.enable_k8s_upgrades && var.allow_remote_manifest_downloads

  # SUC version shorthand — used in download URLs below
  suc_version  = var.cluster_configuration.self_maintenance.system_upgrade_controller_version
  suc_base_url = "https://github.com/rancher/system-upgrade-controller/releases/download/v${local.suc_version}"
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  Kured — Kubernetes Reboot Daemon                                          ║
# ║  Watches /var/run/reboot-required and cordons + reboots nodes one at a time║
# ╚══════════════════════════════════════════════════════════════════════════════╝

resource "kubernetes_namespace_v1" "reboot_daemon" {
  depends_on = [terraform_data.wait_for_infrastructure]

  for_each = local.enable_os_patching ? toset(["kured"]) : toset([])

  metadata {
    name = "kured"
    labels = {
      "app.kubernetes.io/component" = "reboot-daemon"
      "managed-by"                  = "opentofu"
    }
  }

  lifecycle {
    ignore_changes = [metadata[0].annotations, metadata[0].labels]
  }
}

resource "helm_release" "reboot_daemon" {
  depends_on = [kubernetes_namespace_v1.reboot_daemon]

  for_each = local.enable_os_patching ? toset(["kured"]) : toset([])

  name       = "kured"
  repository = "https://kubereboot.github.io/charts"
  chart      = "kured"
  namespace  = "kured"
  version    = var.cluster_configuration.self_maintenance.kured_version
  timeout    = 300

  values = [yamlencode({
    configuration = {
      period = "1h0m0s"
    }
  })]
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  System Upgrade Controller (SUC) — Automated RKE2 patch upgrades           ║
# ║  Downloads CRDs + controller from GitHub, creates server + agent Plans     ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

data "http" "suc_crd_manifest" {
  count = local.enable_suc_download ? 1 : 0
  url   = "${local.suc_base_url}/crd.yaml"
}

# DECISION: Use sha1() of document content as for_each key instead of list index.
# Why: List-index keys (0, 1, 2...) are fragile — if an upstream CRD is added or
#      removed in the middle, all subsequent indices shift and OpenTofu sees
#      destroy+create for unchanged resources. Content-based keys are stable
#      across upstream reorderings.
resource "kubectl_manifest" "suc_crds" {
  depends_on = [terraform_data.wait_for_infrastructure]

  for_each = local.enable_suc_download ? {
    for doc in local.suc_crd_documents : sha1(doc) => doc
  } : {}

  yaml_body = each.value
}

data "http" "suc_controller_manifest" {
  count = local.enable_suc_download ? 1 : 0
  url   = "${local.suc_base_url}/system-upgrade-controller.yaml"
}

# Namespace resources must be applied before other controller resources.
# Split into two resource blocks: namespace first, everything else second.
resource "kubectl_manifest" "suc_namespace" {
  depends_on = [terraform_data.wait_for_infrastructure, kubectl_manifest.suc_crds]

  for_each = local.enable_suc_download ? {
    for doc in local.suc_controller_documents : sha1(doc) => doc
    if strcontains(doc, "kind: Namespace")
  } : {}

  yaml_body = each.value
}

resource "kubectl_manifest" "suc_controller" {
  depends_on = [terraform_data.wait_for_infrastructure, kubectl_manifest.suc_crds, kubectl_manifest.suc_namespace]

  for_each = local.enable_suc_download ? {
    for doc in local.suc_controller_documents : sha1(doc) => doc
    if !strcontains(doc, "kind: Namespace")
  } : {}

  yaml_body = each.value
}

# ── SUC Upgrade Plans ────────────────────────────────────────────────────────
# DECISION: Use yamlencode() to build Plan manifests inline.
# Why: Upstream module uses file() to load static YAML templates. We use
#      yamlencode() for deterministic output and to keep all configuration
#      visible in a single file rather than split across templates.

resource "kubectl_manifest" "suc_server_upgrade_plan" {
  depends_on = [kubectl_manifest.suc_controller]

  for_each = local.enable_k8s_upgrades ? toset(["server-plan"]) : toset([])

  yaml_body = yamlencode({
    apiVersion = "upgrade.cattle.io/v1"
    kind       = "Plan"
    metadata = {
      name      = "server-plan"
      namespace = "system-upgrade"
      labels = {
        "rke2-upgrade" = "server"
      }
    }
    spec = {
      concurrency = 1
      cordon      = true
      nodeSelector = {
        matchExpressions = [
          { key = "rke2-upgrade", operator = "Exists" },
          { key = "rke2-upgrade", operator = "NotIn", values = ["disabled", "false"] },
          { key = "node-role.kubernetes.io/control-plane", operator = "In", values = ["true"] },
        ]
      }
      serviceAccountName = "system-upgrade"
      prepare = {
        image = "rancher/rke2-upgrade"
        args  = ["etcd-snapshot", "save", "--name", "pre-suc-upgrade"]
      }
      upgrade = {
        image = "rancher/rke2-upgrade"
      }
      channel = "https://update.rke2.io/v1-release/channels/stable"
    }
  })
}

resource "kubectl_manifest" "suc_agent_upgrade_plan" {
  depends_on = [kubectl_manifest.suc_controller]

  for_each = local.enable_k8s_upgrades ? toset(["agent-plan"]) : toset([])

  yaml_body = yamlencode({
    apiVersion = "upgrade.cattle.io/v1"
    kind       = "Plan"
    metadata = {
      name      = "agent-plan"
      namespace = "system-upgrade"
      labels = {
        "rke2-upgrade" = "agent"
      }
    }
    spec = {
      concurrency = 2
      cordon      = true
      drain = {
        force              = true
        deleteEmptyDirData = true
        ignoreDaemonSets   = true
        gracePeriodSeconds = 60
      }
      nodeSelector = {
        matchExpressions = [
          { key = "rke2-upgrade", operator = "Exists" },
          { key = "rke2-upgrade", operator = "NotIn", values = ["disabled", "false"] },
          { key = "node-role.kubernetes.io/control-plane", operator = "NotIn", values = ["true"] },
        ]
      }
      serviceAccountName = "system-upgrade"
      prepare = {
        image = "rancher/rke2-upgrade"
        args  = ["prepare", "server-plan"]
      }
      upgrade = {
        image = "rancher/rke2-upgrade"
      }
      channel = "https://update.rke2.io/v1-release/channels/stable"
    }
  })
}
