# ──────────────────────────────────────────────────────────────────────────────
# Unit Tests: Conditional Logic & Resource Branching
#
# DECISION: Tests verify that conditional resource counts match expectations
#           for every major feature toggle in the module.
# Why: Conditional branches are the primary source of plan-time regressions.
#      Asserting resource counts catches unintended changes early.
# See: docs/ARCHITECTURE.md — Dependency Chain
# ──────────────────────────────────────────────────────────────────────────────

# ── Mock all 7 providers so plan runs without credentials ───────────────────
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

# NOTE: data "external" returns a result map with kubeconfig_b64 key.
# Empty string produces empty kubeconfig via try() fallback in locals.tf.
mock_provider "external" {}

mock_provider "aws" {}
mock_provider "cloudinit" {}
mock_provider "random" {}
mock_provider "tls" {}
mock_provider "local" {}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C01: Harmony disabled — no ingress LB                                  ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "harmony_disabled_no_ingress_lb" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    harmony_enabled  = false
  }

  assert {
    condition     = module.infrastructure._test_counts.ingress_lb == 0
    error_message = "Ingress LB should not be created when harmony is disabled."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C02: Harmony enabled — ingress LB created                              ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "harmony_enabled_creates_ingress_lb" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    agent_node_count = 3
    harmony_enabled  = true
  }

  assert {
    condition     = module.infrastructure._test_counts.ingress_lb == 1
    error_message = "Ingress LB must be created when harmony is enabled."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C05: Single master — no additional_masters created                     ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "single_master_no_additional" {
  command = plan

  variables {
    cluster_domain      = "example.com"
    hcloud_api_token    = "mock-token"
    control_plane_count = 1
  }

  assert {
    condition     = module.infrastructure._test_counts.additional_masters == 0
    error_message = "No additional masters should be created when control_plane_count = 1."
  }

  assert {
    condition     = module.infrastructure._test_counts.masters == 1
    error_message = "Exactly one bootstrap master must always be created."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C06: HA cluster — correct number of additional masters                 ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "ha_cluster_creates_additional_masters" {
  command = plan

  variables {
    cluster_domain      = "example.com"
    hcloud_api_token    = "mock-token"
    control_plane_count = 5
  }

  assert {
    condition     = module.infrastructure._test_counts.additional_masters == 4
    error_message = "HA cluster with 5 masters should create 4 additional masters (1 bootstrap + 4)."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C07: Zero workers — no worker nodes created                            ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "zero_workers" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    agent_node_count = 0
  }

  assert {
    condition     = module.infrastructure._test_counts.workers == 0
    error_message = "No worker nodes should be created when agent_node_count = 0."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C08: Workers created — correct count                                   ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "workers_correct_count" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    agent_node_count = 5
  }

  assert {
    condition     = module.infrastructure._test_counts.workers == 5
    error_message = "Worker count must match agent_node_count."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C09: SSH on LB — disabled by default                                   ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "ssh_on_lb_disabled_by_default" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
  }

  assert {
    condition     = module.infrastructure._test_counts.cp_ssh_service == 0
    error_message = "SSH service on control-plane LB should not exist by default."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C10: SSH on LB — enabled when requested                                ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "ssh_on_lb_enabled" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    enable_ssh_on_lb = true
  }

  assert {
    condition     = module.infrastructure._test_counts.cp_ssh_service == 1
    error_message = "SSH service on control-plane LB must exist when enable_ssh_on_lb = true."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C15: save_ssh_key_locally — disabled by default                       ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "ssh_key_file_disabled_by_default" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
  }

  assert {
    condition     = module.infrastructure._test_counts.ssh_key_file == 0
    error_message = "SSH key file should not be generated by default."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C16: save_ssh_key_locally — enabled creates file                      ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "ssh_key_file_enabled" {
  command = plan

  variables {
    cluster_domain       = "example.com"
    hcloud_api_token     = "mock-token"
    save_ssh_key_locally = true
  }

  assert {
    condition     = module.infrastructure._test_counts.ssh_key_file == 1
    error_message = "SSH key file must be generated when save_ssh_key_locally = true."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C17: DNS disabled by default — no Route53 record                       ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "dns_disabled_by_default" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
  }

  assert {
    condition     = module.infrastructure._test_counts.dns_record == 0
    error_message = "Route53 record should not be created by default."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C18: Ingress LB targets match worker count when harmony enabled        ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "ingress_lb_targets_match_workers" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    agent_node_count = 4
    harmony_enabled  = true
  }

  assert {
    condition     = module.infrastructure._test_counts.ingress_lb_targets == 4
    error_message = "Ingress LB worker targets must match agent_node_count."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C19: Control-plane LB always created — even with harmony disabled      ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "control_plane_lb_always_exists" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
  }

  assert {
    condition     = module.infrastructure.control_plane_lb_name == "rke2-cp-lb"
    error_message = "Control-plane LB must always be created with correct name."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C20: Output ingress_lb_ipv4 is null when harmony disabled              ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "output_ingress_null_when_harmony_disabled" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    harmony_enabled  = false
  }

  assert {
    condition     = output.ingress_lb_ipv4 == null
    error_message = "ingress_lb_ipv4 output must be null when harmony is disabled."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C25: Pre-upgrade snapshot — not created when etcd backup disabled      ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "pre_upgrade_snapshot_disabled_by_default" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
  }

  assert {
    condition     = module.infrastructure._test_counts.pre_upgrade_snapshot == 0
    error_message = "Pre-upgrade snapshot should not exist when etcd backup is disabled (default)."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C26: Pre-upgrade snapshot — created when etcd backup enabled           ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "pre_upgrade_snapshot_enabled_with_etcd_backup" {
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

  assert {
    condition     = module.infrastructure._test_counts.pre_upgrade_snapshot == 1
    error_message = "Pre-upgrade snapshot must be created when etcd backup is enabled."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C27: Outputs — etcd_backup_enabled reflects state                      ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "outputs_reflect_backup_state" {
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

  assert {
    condition     = output.etcd_backup_enabled == true
    error_message = "etcd_backup_enabled output must be true when etcd backup is enabled."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C28: OpenBao disabled — no bootstrap token created                     ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "openbao_disabled_no_token" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    openbao_enabled  = false
  }

  assert {
    condition     = module.infrastructure._test_counts.openbao_token == 0
    error_message = "Bootstrap token should not be created when openbao is disabled."
  }

  assert {
    condition     = output.openbao_url == null
    error_message = "openbao_url output must be null when openbao is disabled."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-C29: OpenBao enabled — bootstrap token created                         ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "openbao_enabled_creates_token" {
  command = plan

  variables {
    cluster_domain            = "example.com"
    hcloud_api_token          = "mock-token"
    openbao_enabled           = true
    enable_secrets_encryption = true
    agent_node_count          = 3
  }

  assert {
    condition     = module.infrastructure._test_counts.openbao_token == 1
    error_message = "Bootstrap token must be created when openbao is enabled."
  }

  assert {
    condition     = output.openbao_url == "https://vault.example.com"
    error_message = "openbao_url must point to vault.cluster_domain when openbao is enabled."
  }
}
