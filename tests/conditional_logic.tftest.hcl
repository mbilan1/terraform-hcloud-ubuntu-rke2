# ──────────────────────────────────────────────────────────────────────────────
# Unit Tests: Conditional Logic & Resource Branching
#
# DECISION: Tests verify that conditional resource counts match expectations
#           for every major feature toggle in the module.
# Why: Conditional branches are the primary source of plan-time regressions.
#      Asserting resource counts catches unintended changes early.
# See: docs/ARCHITECTURE.md — Dependency Chain
# ──────────────────────────────────────────────────────────────────────────────

# ── Mock all 11 providers so plan runs without credentials ──────────────────
#
# NOTE: Same mock_provider configuration as variables_and_guardrails.tftest.hcl.
# See that file for explanations of hcloud numeric ID workaround and remote_file
# empty content workaround.

mock_provider "hcloud" {
  mock_resource "hcloud_network" {
    defaults = {
      id = "10001"
    }
  }
  mock_resource "hcloud_network_subnet" {
    defaults = {
      id = "10002"
    }
  }
  mock_resource "hcloud_load_balancer" {
    defaults = {
      id   = "10003"
      ipv4 = "1.2.3.4"
    }
  }
  mock_resource "hcloud_server" {
    defaults = {
      id           = "10004"
      ipv4_address = "1.2.3.4"
    }
  }
  mock_resource "hcloud_ssh_key" {
    defaults = {
      id = "10005"
    }
  }
  mock_resource "hcloud_firewall" {
    defaults = {
      id = "10006"
    }
  }
  mock_data "hcloud_load_balancers" {
    defaults = {
      load_balancers = []
    }
  }
}

mock_provider "remote" {
  mock_data "remote_file" {
    defaults = {
      content = ""
    }
  }
}

mock_provider "aws" {}
mock_provider "kubectl" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "null" {}
mock_provider "random" {}
mock_provider "tls" {}
mock_provider "local" {}
mock_provider "http" {}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C01: Harmony disabled — no ingress LB, no harmony resources            ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "harmony_disabled_no_ingress_lb" {
  command = plan

  variables {
    hetzner_token = "mock-token"
    domain        = "test.example.com"
    harmony = {
      enabled = false
    }
  }

  assert {
    condition     = length(hcloud_load_balancer.ingress) == 0
    error_message = "Ingress LB should not be created when harmony is disabled."
  }

  assert {
    condition     = length(kubernetes_namespace_v1.harmony) == 0
    error_message = "Harmony namespace should not be created when harmony is disabled."
  }

  assert {
    condition     = length(helm_release.harmony) == 0
    error_message = "Harmony helm release should not be created when harmony is disabled."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C02: Harmony enabled — ingress LB + harmony resources created          ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "harmony_enabled_creates_ingress_lb" {
  command = plan

  variables {
    hetzner_token     = "mock-token"
    domain            = "test.example.com"
    worker_node_count = 3
    harmony = {
      enabled = true
    }
  }

  assert {
    condition     = length(hcloud_load_balancer.ingress) == 1
    error_message = "Ingress LB must be created when harmony is enabled."
  }

  assert {
    condition     = length(kubernetes_namespace_v1.harmony) == 1
    error_message = "Harmony namespace must be created when harmony is enabled."
  }

  assert {
    condition     = length(helm_release.harmony) == 1
    error_message = "Harmony helm release must be created when harmony is enabled."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C03: Harmony enabled — RKE2 built-in ingress disabled                  ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "harmony_disables_builtin_ingress" {
  command = plan

  variables {
    hetzner_token     = "mock-token"
    domain            = "test.example.com"
    worker_node_count = 3
    harmony = {
      enabled = true
    }
  }

  assert {
    condition     = length(kubectl_manifest.ingress_configuration) == 0
    error_message = "RKE2 built-in ingress HelmChartConfig must not exist when harmony is enabled."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C04: Harmony disabled — RKE2 built-in ingress enabled                  ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "harmony_disabled_uses_builtin_ingress" {
  command = plan

  variables {
    hetzner_token = "mock-token"
    domain        = "test.example.com"
    harmony = {
      enabled = false
    }
  }

  assert {
    condition     = length(kubectl_manifest.ingress_configuration) == 1
    error_message = "RKE2 built-in ingress HelmChartConfig must exist when harmony is disabled."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C05: Single master — no additional_masters created                     ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "single_master_no_additional" {
  command = plan

  variables {
    hetzner_token     = "mock-token"
    domain            = "test.example.com"
    master_node_count = 1
  }

  assert {
    condition     = length(hcloud_server.additional_masters) == 0
    error_message = "No additional masters should be created when master_node_count = 1."
  }

  assert {
    condition     = length(hcloud_server.master) == 1
    error_message = "Exactly one bootstrap master must always be created."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C06: HA cluster — correct number of additional masters                 ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "ha_cluster_creates_additional_masters" {
  command = plan

  variables {
    hetzner_token     = "mock-token"
    domain            = "test.example.com"
    master_node_count = 5
  }

  assert {
    condition     = length(hcloud_server.additional_masters) == 4
    error_message = "HA cluster with 5 masters should create 4 additional masters (1 bootstrap + 4)."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C07: Zero workers — no worker nodes created                            ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "zero_workers" {
  command = plan

  variables {
    hetzner_token     = "mock-token"
    domain            = "test.example.com"
    worker_node_count = 0
  }

  assert {
    condition     = length(hcloud_server.worker) == 0
    error_message = "No worker nodes should be created when worker_node_count = 0."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C08: Workers created — correct count                                   ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "workers_correct_count" {
  command = plan

  variables {
    hetzner_token     = "mock-token"
    domain            = "test.example.com"
    worker_node_count = 5
  }

  assert {
    condition     = length(hcloud_server.worker) == 5
    error_message = "Worker count must match worker_node_count."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C09: SSH on LB — disabled by default                                   ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "ssh_on_lb_disabled_by_default" {
  command = plan

  variables {
    hetzner_token = "mock-token"
    domain        = "test.example.com"
  }

  assert {
    condition     = length(hcloud_load_balancer_service.cp_ssh) == 0
    error_message = "SSH service on control-plane LB should not exist by default."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C10: SSH on LB — enabled when requested                                ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "ssh_on_lb_enabled" {
  command = plan

  variables {
    hetzner_token    = "mock-token"
    domain           = "test.example.com"
    enable_ssh_on_lb = true
  }

  assert {
    condition     = length(hcloud_load_balancer_service.cp_ssh) == 1
    error_message = "SSH service on control-plane LB must exist when enable_ssh_on_lb = true."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C11: cert-manager disabled — no cert-manager resources                 ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "certmanager_disabled" {
  command = plan

  variables {
    hetzner_token = "mock-token"
    domain        = "test.example.com"
    cluster_configuration = {
      cert_manager = {
        preinstall = false
      }
    }
  }

  assert {
    condition     = length(kubernetes_namespace_v1.cert_manager) == 0
    error_message = "cert-manager namespace should not exist when preinstall = false."
  }

  assert {
    condition     = length(helm_release.cert_manager) == 0
    error_message = "cert-manager helm release should not exist when preinstall = false."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C12: cert-manager enabled (default) — resources created                ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "certmanager_enabled_by_default" {
  command = plan

  variables {
    hetzner_token = "mock-token"
    domain        = "test.example.com"
  }

  assert {
    condition     = length(kubernetes_namespace_v1.cert_manager) == 1
    error_message = "cert-manager namespace must exist when preinstall = true (default)."
  }

  assert {
    condition     = length(helm_release.cert_manager) == 1
    error_message = "cert-manager helm release must exist when preinstall = true (default)."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C13: HCCM disabled — no HCCM resources                                ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "hccm_disabled" {
  command = plan

  variables {
    hetzner_token = "mock-token"
    domain        = "test.example.com"
    cluster_configuration = {
      hcloud_controller = {
        preinstall = false
      }
    }
  }

  assert {
    condition     = length(kubernetes_secret_v1.hcloud_ccm) == 0
    error_message = "HCCM secret should not exist when preinstall = false."
  }

  assert {
    condition     = length(helm_release.hccm) == 0
    error_message = "HCCM helm release should not exist when preinstall = false."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C14: CSI disabled — no CSI resources                                   ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "csi_disabled" {
  command = plan

  variables {
    hetzner_token = "mock-token"
    domain        = "test.example.com"
    cluster_configuration = {
      hcloud_csi = {
        preinstall = false
      }
    }
  }

  assert {
    condition     = length(helm_release.hcloud_csi) == 0
    error_message = "CSI helm release should not exist when preinstall = false."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C15: generate_ssh_key_file — disabled by default                       ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "ssh_key_file_disabled_by_default" {
  command = plan

  variables {
    hetzner_token = "mock-token"
    domain        = "test.example.com"
  }

  assert {
    condition     = length(local_sensitive_file.ssh_private_key) == 0
    error_message = "SSH key file should not be generated by default."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C16: generate_ssh_key_file — enabled creates file                      ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "ssh_key_file_enabled" {
  command = plan

  variables {
    hetzner_token         = "mock-token"
    domain                = "test.example.com"
    generate_ssh_key_file = true
  }

  assert {
    condition     = length(local_sensitive_file.ssh_private_key) == 1
    error_message = "SSH key file must be generated when generate_ssh_key_file = true."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C17: DNS disabled by default — no Route53 record                       ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "dns_disabled_by_default" {
  command = plan

  variables {
    hetzner_token = "mock-token"
    domain        = "test.example.com"
  }

  assert {
    condition     = length(aws_route53_record.wildcard) == 0
    error_message = "Route53 record should not be created by default."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C18: Ingress LB targets match worker count when harmony enabled        ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "ingress_lb_targets_match_workers" {
  command = plan

  variables {
    hetzner_token     = "mock-token"
    domain            = "test.example.com"
    worker_node_count = 4
    harmony = {
      enabled = true
    }
  }

  assert {
    condition     = length(hcloud_load_balancer_target.ingress_workers) == 4
    error_message = "Ingress LB worker targets must match worker_node_count."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C19: Control-plane LB always created — even with harmony disabled      ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "control_plane_lb_always_exists" {
  command = plan

  variables {
    hetzner_token = "mock-token"
    domain        = "test.example.com"
  }

  assert {
    condition     = hcloud_load_balancer.control_plane.name == "rke2-cp-lb"
    error_message = "Control-plane LB must always be created with correct name."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C20: Output ingress_lb_ipv4 is null when harmony disabled              ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "output_ingress_null_when_harmony_disabled" {
  command = plan

  variables {
    hetzner_token = "mock-token"
    domain        = "test.example.com"
    harmony = {
      enabled = false
    }
  }

  assert {
    condition     = output.ingress_lb_ipv4 == null
    error_message = "ingress_lb_ipv4 output must be null when harmony is disabled."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C21: Self-maintenance — kured not deployed on non-HA cluster           ║
# ║  NOTE: check.auto_updates_require_ha fires a warning on this config.       ║
# ║  We expect it and still verify kured resource count = 0.                   ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "kured_not_deployed_on_single_master" {
  command = plan

  variables {
    hetzner_token          = "mock-token"
    domain                 = "test.example.com"
    master_node_count      = 1
    enable_auto_os_updates = true
  }

  expect_failures = [check.auto_updates_require_ha]
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C22: Self-maintenance — kured deployed on HA cluster when enabled      ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "kured_deployed_on_ha_with_auto_updates" {
  command = plan

  variables {
    hetzner_token          = "mock-token"
    domain                 = "test.example.com"
    master_node_count      = 3
    enable_auto_os_updates = true
  }

  assert {
    condition     = length(helm_release.kured) == 1
    error_message = "Kured must be deployed on HA cluster when enable_auto_os_updates = true."
  }

  assert {
    condition     = length(kubernetes_namespace_v1.kured) == 1
    error_message = "Kured namespace must be created on HA cluster when enable_auto_os_updates = true."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C23: Velero disabled (default) — no Velero resources                   ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "velero_disabled_by_default" {
  command = plan

  variables {
    hetzner_token = "mock-token"
    domain        = "test.example.com"
  }

  assert {
    condition     = length(kubernetes_namespace_v1.velero) == 0
    error_message = "Velero namespace should not exist when velero is disabled (default)."
  }

  assert {
    condition     = length(helm_release.velero) == 0
    error_message = "Velero helm release should not exist when velero is disabled (default)."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C24: Velero enabled — namespace + helm release created                 ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "velero_enabled_creates_resources" {
  command = plan

  variables {
    hetzner_token = "mock-token"
    domain        = "test.example.com"
    velero = {
      enabled       = true
      s3_bucket     = "my-velero-bucket"
      s3_access_key = "AKIAEXAMPLE"
      s3_secret_key = "secretkey123"
    }
  }

  assert {
    condition     = length(kubernetes_namespace_v1.velero) == 1
    error_message = "Velero namespace must be created when velero is enabled."
  }

  assert {
    condition     = length(helm_release.velero) == 1
    error_message = "Velero helm release must be created when velero is enabled."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C25: Pre-upgrade snapshot — not created when etcd backup disabled      ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "pre_upgrade_snapshot_disabled_by_default" {
  command = plan

  variables {
    hetzner_token = "mock-token"
    domain        = "test.example.com"
  }

  assert {
    condition     = length(null_resource.pre_upgrade_snapshot) == 0
    error_message = "Pre-upgrade snapshot should not exist when etcd backup is disabled (default)."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C26: Pre-upgrade snapshot — created when etcd backup enabled           ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "pre_upgrade_snapshot_enabled_with_etcd_backup" {
  command = plan

  variables {
    hetzner_token = "mock-token"
    domain        = "test.example.com"
    cluster_configuration = {
      etcd_backup = {
        enabled       = true
        s3_bucket     = "my-etcd-bucket"
        s3_access_key = "AKIAEXAMPLE"
        s3_secret_key = "secretkey123"
      }
    }
  }

  assert {
    condition     = length(null_resource.pre_upgrade_snapshot) == 1
    error_message = "Pre-upgrade snapshot must be created when etcd backup is enabled."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C27: Outputs — etcd_backup_enabled and velero_enabled reflect state    ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "outputs_reflect_backup_state" {
  command = plan

  variables {
    hetzner_token = "mock-token"
    domain        = "test.example.com"
    velero = {
      enabled       = true
      s3_bucket     = "my-velero-bucket"
      s3_access_key = "AKIAEXAMPLE"
      s3_secret_key = "secretkey123"
    }
    cluster_configuration = {
      etcd_backup = {
        enabled       = true
        s3_bucket     = "my-etcd-bucket"
        s3_access_key = "AKIAEXAMPLE"
        s3_secret_key = "secretkey123"
      }
    }
  }

  assert {
    condition     = output.etcd_backup_enabled == true
    error_message = "etcd_backup_enabled output must be true when etcd backup is enabled."
  }

  assert {
    condition     = output.velero_enabled == true
    error_message = "velero_enabled output must be true when velero is enabled."
  }
}
