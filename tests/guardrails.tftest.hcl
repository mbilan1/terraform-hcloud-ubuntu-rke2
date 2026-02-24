# ──────────────────────────────────────────────────────────────────────────────
# Unit Tests: Cross-Variable Guardrails (check blocks)
#
# DECISION: All tests use command = plan with mock_provider to run offline
#           without cloud credentials, at zero cost, in ~1 second.
# Why: tofu test with mock providers evaluates check blocks during plan phase.
# See: docs/ARCHITECTURE.md
# ──────────────────────────────────────────────────────────────────────────────

# ── Mock all 11 providers so plan runs without credentials ──────────────────
#
# WORKAROUND: Hetzner provider uses numeric IDs internally, but Terraform
# resource `id` attribute is always a string. With mock providers, the
# auto-generated string IDs (e.g. "72oy3AZL") cannot be coerced to numbers,
# causing plan failures. We override IDs with numeric strings that coerce
# correctly (e.g. "10001" → 10001).
# TODO: Remove mock_resource overrides if OpenTofu adds type-aware mock generation

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

# WORKAROUND: remote_file mock must return empty content to avoid yamldecode()
# failure in locals.tf kubeconfig parsing. Empty string triggers the safe
# conditional branch: `content == "" ? "" : base64decode(yamldecode(...))`.
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
mock_provider "cloudinit" {}
mock_provider "random" {}
mock_provider "tls" {}
mock_provider "local" {}
mock_provider "http" {}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-G01: aws_credentials_pair_consistency                                  ║
# ║  Only one of aws_access_key / aws_secret_key set → warning                 ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "aws_credentials_rejects_partial" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    domain           = "test.example.com"
    aws_access_key   = "AKIAEXAMPLE"
    aws_secret_key   = ""
  }

  expect_failures = [check.aws_credentials_pair_consistency]
}

run "aws_credentials_accepts_both_set" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    domain           = "test.example.com"
    aws_access_key   = "AKIAEXAMPLE"
    aws_secret_key   = "secretkey123"
  }
}

run "aws_credentials_accepts_both_empty" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    domain           = "test.example.com"
    aws_access_key   = ""
    aws_secret_key   = ""
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-G02: letsencrypt_email_required_when_issuer_enabled                    ║
# ║  cert_manager with route53_zone_id but no email → warning                  ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "letsencrypt_email_required_with_route53" {
  command = plan

  variables {
    cluster_domain     = "example.com"
    hcloud_api_token   = "mock-token"
    domain             = "test.example.com"
    route53_zone_id    = "Z1234567890"
    letsencrypt_issuer = ""
    aws_access_key     = "AKIAEXAMPLE"
    aws_secret_key     = "secretkey123"
  }

  expect_failures = [check.letsencrypt_email_required_when_issuer_enabled]
}

run "letsencrypt_email_passes_when_set" {
  command = plan

  variables {
    cluster_domain     = "example.com"
    hcloud_api_token   = "mock-token"
    domain             = "test.example.com"
    route53_zone_id    = "Z1234567890"
    letsencrypt_issuer = "admin@example.com"
    aws_access_key     = "AKIAEXAMPLE"
    aws_secret_key     = "secretkey123"
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-G03: system_upgrade_controller_version_format                          ║
# ║  Version must be numeric semver (no 'v' prefix)                            ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "suc_version_rejects_v_prefix" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    domain           = "test.example.com"
    cluster_configuration = {
      self_maintenance = {
        system_upgrade_controller_version = "v0.13.4"
      }
    }
  }

  expect_failures = [check.system_upgrade_controller_version_format]
}

run "suc_version_accepts_valid" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    domain           = "test.example.com"
    cluster_configuration = {
      self_maintenance = {
        system_upgrade_controller_version = "0.13.4"
      }
    }
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-G04: remote_manifest_downloads_required_for_selected_features          ║
# ║  auto k8s updates ON + downloads OFF → warning                             ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "remote_downloads_required_for_k8s_updates" {
  command = plan

  variables {
    cluster_domain                  = "example.com"
    hcloud_api_token                = "mock-token"
    domain                          = "test.example.com"
    enable_auto_kubernetes_updates  = true
    allow_remote_manifest_downloads = false
  }

  expect_failures = [check.remote_manifest_downloads_required_for_selected_features]
}

run "remote_downloads_passes_when_enabled" {
  command = plan

  variables {
    cluster_domain                  = "example.com"
    hcloud_api_token                = "mock-token"
    domain                          = "test.example.com"
    enable_auto_kubernetes_updates  = true
    allow_remote_manifest_downloads = true
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-G04b: workers_must_not_mix_countries                                    ║
# ║  enforce_single_country_workers=true → workers must be DE-only or FI-only   ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "workers_country_policy_passes_germany" {
  command = plan

  variables {
    cluster_domain                 = "example.com"
    hcloud_api_token               = "mock-token"
    domain                         = "test.example.com"
    enforce_single_country_workers = true
    worker_node_locations          = ["nbg1", "fsn1"]
  }
}

run "workers_country_policy_passes_finland" {
  command = plan

  variables {
    cluster_domain                 = "example.com"
    hcloud_api_token               = "mock-token"
    domain                         = "test.example.com"
    enforce_single_country_workers = true
    worker_node_locations          = ["hel1"]
  }
}

run "workers_country_policy_rejects_mixed" {
  command = plan

  variables {
    cluster_domain                 = "example.com"
    hcloud_api_token               = "mock-token"
    domain                         = "test.example.com"
    enforce_single_country_workers = true
    worker_node_locations          = ["hel1", "nbg1"]
  }

  expect_failures = [check.workers_must_not_mix_countries]
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-G05: kubernetes_version_format_when_pinned                                   ║
# ║  Pinned version must match v1.31.6+rke2r1 format                           ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "kubernetes_version_rejects_bad_format" {
  command = plan

  variables {
    cluster_domain     = "example.com"
    hcloud_api_token   = "mock-token"
    domain             = "test.example.com"
    kubernetes_version = "1.31.6"
  }

  expect_failures = [check.kubernetes_version_format_when_pinned]
}

run "kubernetes_version_accepts_empty" {
  command = plan

  variables {
    cluster_domain     = "example.com"
    hcloud_api_token   = "mock-token"
    domain             = "test.example.com"
    kubernetes_version = ""
  }
}

run "kubernetes_version_accepts_valid_format" {
  command = plan

  variables {
    cluster_domain     = "example.com"
    hcloud_api_token   = "mock-token"
    domain             = "test.example.com"
    kubernetes_version = "v1.31.6+rke2r1"
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-G06: auto_updates_require_ha (cluster-selfmaintenance.tf)              ║
# ║  Auto-updates ON + single master → warning                                 ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "auto_updates_warns_on_single_master" {
  command = plan

  variables {
    cluster_domain         = "example.com"
    hcloud_api_token       = "mock-token"
    domain                 = "test.example.com"
    control_plane_count    = 1
    enable_auto_os_updates = true
  }

  expect_failures = [check.auto_updates_require_ha]
}

run "auto_updates_passes_on_ha" {
  command = plan

  variables {
    cluster_domain         = "example.com"
    hcloud_api_token       = "mock-token"
    domain                 = "test.example.com"
    control_plane_count    = 3
    enable_auto_os_updates = true
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-G07: harmony_requires_cert_manager (cluster-harmony.tf)                ║
# ║  Harmony ON + cert_manager OFF → warning                                   ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "harmony_requires_cert_manager" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    domain           = "test.example.com"
    harmony = {
      enabled = true
    }
    cluster_configuration = {
      cert_manager = {
        preinstall = false
      }
    }
  }

  expect_failures = [check.harmony_requires_cert_manager]
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-G08: harmony_requires_workers_for_lb (cluster-harmony.tf)              ║
# ║  Harmony ON + 0 workers → warning                                          ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "harmony_requires_workers" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    domain           = "test.example.com"
    agent_node_count = 0
    harmony = {
      enabled = true
    }
  }

  expect_failures = [check.harmony_requires_workers_for_lb]
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-G09 / UT-G10: dns_requires_zone_id / dns_requires_harmony_ingress     ║
# ║                                                                            ║
# ║  COMPROMISE: These two check blocks cannot be tested with mock_provider.   ║
# ║  Why: Setting create_dns_record=true with invalid inputs triggers both      ║
# ║  the check block WARNING and a downstream provider schema error on          ║
# ║  aws_route53_record.wildcard (zone_id required, ingress[0] index OOB).     ║
# ║  Provider schema errors are not catchable via expect_failures — only        ║
# ║  checkable objects (variables, check blocks, postconditions) can be         ║
# ║  expected. The uncatchable schema error causes test failure regardless.     ║
# ║  These check blocks are validated in real deployments and via code review.  ║
# ║  TODO: Add when OpenTofu supports expect_failures for provider errors.     ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-G11: etcd_backup_requires_s3_config                                    ║
# ║  etcd_backup enabled without S3 credentials → warning                      ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "etcd_backup_rejects_missing_s3" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    domain           = "test.example.com"
    cluster_configuration = {
      etcd_backup = {
        enabled = true
        # s3_bucket, s3_access_key, s3_secret_key intentionally omitted (empty defaults)
      }
    }
  }

  expect_failures = [check.etcd_backup_requires_s3_config]
}

run "etcd_backup_passes_with_s3" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    domain           = "test.example.com"
    cluster_configuration = {
      etcd_backup = {
        enabled       = true
        s3_bucket     = "my-etcd-bucket"
        s3_access_key = "AKIAEXAMPLE"
        s3_secret_key = "secretkey123"
      }
    }
  }
}

run "etcd_backup_passes_when_disabled" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    domain           = "test.example.com"
    cluster_configuration = {
      etcd_backup = {
        enabled = false
      }
    }
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-G14: longhorn_and_csi_default_sc_exclusivity                           ║
# ║  Both Longhorn and CSI as default StorageClass → warning                   ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "longhorn_and_csi_both_default_rejects" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    domain           = "test.example.com"
    cluster_configuration = {
      longhorn = {
        preinstall            = true
        default_storage_class = true
      }
      hcloud_csi = {
        preinstall            = true
        default_storage_class = true
      }
    }
  }

  expect_failures = [
    check.longhorn_and_csi_default_sc_exclusivity,
    check.longhorn_experimental_warning,
  ]
}

run "longhorn_default_csi_not_default_passes" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    domain           = "test.example.com"
    cluster_configuration = {
      longhorn = {
        preinstall            = true
        default_storage_class = true
      }
      hcloud_csi = {
        preinstall            = true
        default_storage_class = false
      }
    }
  }

  # NOTE: Longhorn experimental warning always fires when preinstall = true
  expect_failures = [check.longhorn_experimental_warning]
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-G15: longhorn_experimental_warning                                     ║
# ║  Longhorn enabled → experimental warning                                   ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "longhorn_experimental_warning_fires" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    domain           = "test.example.com"
    cluster_configuration = {
      longhorn = {
        preinstall = true
      }
    }
  }

  expect_failures = [
    check.longhorn_experimental_warning,
    check.longhorn_and_csi_default_sc_exclusivity,
  ]
}

run "longhorn_experimental_warning_does_not_fire_when_disabled" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    domain           = "test.example.com"
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-G16: longhorn_backup_requires_s3_config                                ║
# ║  Longhorn backup_target without S3 credentials → warning                   ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "longhorn_backup_rejects_missing_s3" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    domain           = "test.example.com"
    cluster_configuration = {
      longhorn = {
        preinstall    = true
        backup_target = "s3://my-bucket@eu-central/backups"
        # s3_access_key, s3_secret_key intentionally omitted (empty defaults)
      }
    }
  }

  expect_failures = [
    check.longhorn_backup_requires_s3_config,
    check.longhorn_experimental_warning,
    check.longhorn_and_csi_default_sc_exclusivity,
  ]
}

run "longhorn_backup_passes_with_s3" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    domain           = "test.example.com"
    cluster_configuration = {
      longhorn = {
        preinstall    = true
        backup_target = "s3://my-bucket@eu-central/backups"
        s3_access_key = "AKIAEXAMPLE"
        s3_secret_key = "secretkey123"
      }
    }
  }

  # NOTE: This also expects the experimental warning (it always fires when enabled)
  # NOTE: SC exclusivity fires because both longhorn and hcloud_csi default to default_storage_class = true
  expect_failures = [
    check.longhorn_experimental_warning,
    check.longhorn_and_csi_default_sc_exclusivity,
  ]
}

run "longhorn_backup_passes_without_target" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    domain           = "test.example.com"
    cluster_configuration = {
      longhorn = {
        preinstall = true
        # No backup_target → S3 config not required
      }
    }
  }

  # NOTE: Experimental warning still fires
  # NOTE: SC exclusivity fires because both longhorn and hcloud_csi default to default_storage_class = true
  expect_failures = [
    check.longhorn_experimental_warning,
    check.longhorn_and_csi_default_sc_exclusivity,
  ]
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-G17: longhorn_minimum_workers                                          ║
# ║  Longhorn RF=2 with only 1 worker → warning                               ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "longhorn_rejects_insufficient_workers" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    domain           = "test.example.com"
    agent_node_count = 1
    cluster_configuration = {
      longhorn = {
        preinstall    = true
        replica_count = 2
      }
    }
  }

  expect_failures = [
    check.longhorn_minimum_workers,
    check.longhorn_experimental_warning,
    check.longhorn_and_csi_default_sc_exclusivity,
  ]
}

run "longhorn_passes_with_enough_workers" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    domain           = "test.example.com"
    agent_node_count = 3
    cluster_configuration = {
      longhorn = {
        preinstall    = true
        replica_count = 2
      }
    }
  }

  # Only the experimental warning should fire, not the minimum workers check
  # NOTE: SC exclusivity fires because both longhorn and hcloud_csi default to default_storage_class = true
  expect_failures = [
    check.longhorn_experimental_warning,
    check.longhorn_and_csi_default_sc_exclusivity,
  ]
}

