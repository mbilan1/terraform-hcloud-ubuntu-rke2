# ──────────────────────────────────────────────────────────────────────────────
# Unit Tests: Cross-Variable Guardrails (check blocks)
#
# DECISION: All tests use command = plan with mock_provider to run offline
#           without cloud credentials, at zero cost, in ~1 second.
# Why: tofu test with mock providers evaluates check blocks during plan phase.
# See: docs/ARCHITECTURE.md
# ──────────────────────────────────────────────────────────────────────────────

# ── Mock all 7 providers so plan runs without credentials ───────────────────
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

# NOTE: data "external" returns a result map with kubeconfig_b64 key.
# Empty string produces empty kubeconfig via try() fallback in locals.tf.
mock_provider "external" {}

mock_provider "aws" {}
mock_provider "cloudinit" {}
mock_provider "random" {}
mock_provider "tls" {}
mock_provider "local" {}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-G01: aws_credentials_pair_consistency                                  ║
# ║  Only one of aws_access_key / aws_secret_key set → warning                 ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "aws_credentials_rejects_partial" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
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
    aws_access_key   = "AKIAEXAMPLE"
    aws_secret_key   = "secretkey123"
  }
}

run "aws_credentials_accepts_both_empty" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    aws_access_key   = ""
    aws_secret_key   = ""
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
    enforce_single_country_workers = true
    worker_node_locations          = ["nbg1", "fsn1"]
  }
}

run "workers_country_policy_passes_finland" {
  command = plan

  variables {
    cluster_domain                 = "example.com"
    hcloud_api_token               = "mock-token"
    enforce_single_country_workers = true
    worker_node_locations          = ["hel1"]
  }
}

run "workers_country_policy_rejects_mixed" {
  command = plan

  variables {
    cluster_domain                 = "example.com"
    hcloud_api_token               = "mock-token"
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
    kubernetes_version = "1.31.6"
  }

  # NOTE: Variable-level validation{} fires before the check{} block runs,
  # so we must expect the variable error here, not the guardrail check.
  expect_failures = [var.kubernetes_version]
}

run "kubernetes_version_accepts_empty" {
  command = plan

  variables {
    cluster_domain     = "example.com"
    hcloud_api_token   = "mock-token"
    kubernetes_version = ""
  }
}

run "kubernetes_version_accepts_valid_format" {
  command = plan

  variables {
    cluster_domain     = "example.com"
    hcloud_api_token   = "mock-token"
    kubernetes_version = "v1.31.6+rke2r1"
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-G08: harmony_requires_workers_for_lb                                   ║
# ║  Harmony ON + 0 workers → warning                                          ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "harmony_requires_workers" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    agent_node_count = 0
    harmony_enabled  = true
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
    cluster_configuration = {
      etcd_backup = {
        enabled = false
      }
    }
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-G14: openbao_requires_workers                                          ║
# ║  OpenBao enabled without workers → warning                                 ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "openbao_requires_workers" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    agent_node_count = 0
    openbao_enabled  = true
  }

  expect_failures = [check.openbao_requires_workers]
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-G15: openbao_requires_secrets_encryption                               ║
# ║  OpenBao enabled without secrets encryption → warning                      ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "openbao_requires_secrets_encryption" {
  command = plan

  variables {
    cluster_domain            = "example.com"
    hcloud_api_token          = "mock-token"
    openbao_enabled           = true
    enable_secrets_encryption = false
  }

  expect_failures = [check.openbao_requires_secrets_encryption]
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-G16: openbao_passes_with_valid_config                                  ║
# ║  OpenBao enabled with workers + encryption → pass                          ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "openbao_passes_with_valid_config" {
  command = plan

  variables {
    cluster_domain            = "example.com"
    hcloud_api_token          = "mock-token"
    agent_node_count          = 3
    openbao_enabled           = true
    enable_secrets_encryption = true
  }
}
