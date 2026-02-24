# ──────────────────────────────────────────────────────────────────────────────
# Unit Tests: Variable Validations
#
# DECISION: All tests use command = plan with mock_provider to run offline
#           without cloud credentials, at zero cost, in ~2 seconds.
# Why: tofu test with mock providers evaluates validation and check blocks
#      during the plan phase. No real infrastructure is created.
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
# ║  UT-V01: Default values pass validation                                   ║
# ║  Verifies the module is valid with only required variables set.            ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "defaults_pass_validation" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token-for-testing"
    domain           = "test.example.com"
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-V02: domain — must not be empty                                       ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "domain_rejects_empty_string" {
  command = plan

  variables {
    cluster_domain   = ""
    hcloud_api_token = "mock-token"
    domain           = ""
  }

  expect_failures = [var.cluster_domain]
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-V03: control_plane_count — rejects 2 (split-brain)                      ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "master_count_rejects_two" {
  command = plan

  variables {
    cluster_domain      = "example.com"
    hcloud_api_token    = "mock-token"
    domain              = "test.example.com"
    control_plane_count = 2
  }

  expect_failures = [var.control_plane_count]
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-V04: control_plane_count — accepts 1 (non-HA)                           ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "master_count_accepts_one" {
  command = plan

  variables {
    cluster_domain      = "example.com"
    hcloud_api_token    = "mock-token"
    domain              = "test.example.com"
    control_plane_count = 1
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-V05: control_plane_count — accepts 3 (HA)                               ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "master_count_accepts_three" {
  command = plan

  variables {
    cluster_domain      = "example.com"
    hcloud_api_token    = "mock-token"
    domain              = "test.example.com"
    control_plane_count = 3
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-V06: control_plane_count — accepts 5 (large HA)                         ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "master_count_accepts_five" {
  command = plan

  variables {
    cluster_domain      = "example.com"
    hcloud_api_token    = "mock-token"
    domain              = "test.example.com"
    control_plane_count = 5
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-V07: rke2_cluster_name — rejects invalid characters                        ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "rke2_cluster_name_rejects_uppercase" {
  command = plan

  variables {
    cluster_domain    = "example.com"
    hcloud_api_token  = "mock-token"
    domain            = "test.example.com"
    rke2_cluster_name = "MyCluster"
  }

  expect_failures = [var.rke2_cluster_name]
}

run "rke2_cluster_name_rejects_hyphens" {
  command = plan

  variables {
    cluster_domain    = "example.com"
    hcloud_api_token  = "mock-token"
    domain            = "test.example.com"
    rke2_cluster_name = "my-cluster"
  }

  expect_failures = [var.rke2_cluster_name]
}

run "rke2_cluster_name_rejects_too_long" {
  command = plan

  variables {
    cluster_domain    = "example.com"
    hcloud_api_token  = "mock-token"
    domain            = "test.example.com"
    rke2_cluster_name = "aaaaabbbbbcccccddddde"
  }

  expect_failures = [var.rke2_cluster_name]
}

run "rke2_cluster_name_accepts_valid" {
  command = plan

  variables {
    cluster_domain    = "example.com"
    hcloud_api_token  = "mock-token"
    domain            = "test.example.com"
    rke2_cluster_name = "prod01"
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-V08: cni_plugin — rejects invalid value                                 ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "cni_plugin_rejects_invalid" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    domain           = "test.example.com"
    cni_plugin       = "flannel"
  }

  expect_failures = [var.cni_plugin]
}

run "cni_plugin_accepts_cilium" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    domain           = "test.example.com"
    cni_plugin       = "cilium"
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-V09: extra_lb_ports — rejects out-of-range ports          ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "lb_ports_rejects_zero" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    domain           = "test.example.com"
    extra_lb_ports   = [0]
  }

  expect_failures = [var.extra_lb_ports]
}

run "lb_ports_rejects_too_large" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    domain           = "test.example.com"
    extra_lb_ports   = [65536]
  }

  expect_failures = [var.extra_lb_ports]
}

run "lb_ports_accepts_valid" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    domain           = "test.example.com"
    extra_lb_ports   = [8080, 8443]
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-V10: hcloud_network_cidr — rejects invalid CIDR                            ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "hcloud_network_cidr_rejects_invalid" {
  command = plan

  variables {
    cluster_domain      = "example.com"
    hcloud_api_token    = "mock-token"
    domain              = "test.example.com"
    hcloud_network_cidr = "not-a-cidr"
  }

  expect_failures = [var.hcloud_network_cidr]
}

run "hcloud_network_cidr_accepts_valid" {
  command = plan

  variables {
    cluster_domain      = "example.com"
    hcloud_api_token    = "mock-token"
    domain              = "test.example.com"
    hcloud_network_cidr = "172.16.0.0/12"
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-V11: subnet_address — rejects invalid CIDR                             ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "subnet_address_rejects_invalid" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    domain           = "test.example.com"
    subnet_address   = "999.999.999.0/24"
  }

  expect_failures = [var.subnet_address]
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-V12: cluster_configuration.hcloud_csi.reclaim_policy — enum            ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "reclaim_policy_rejects_invalid" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    domain           = "test.example.com"
    cluster_configuration = {
      hcloud_csi = {
        reclaim_policy = "Recycle"
      }
    }
  }

  expect_failures = [var.cluster_configuration]
}

run "reclaim_policy_accepts_retain" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    domain           = "test.example.com"
    cluster_configuration = {
      hcloud_csi = {
        reclaim_policy = "Retain"
      }
    }
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-V13a: ssh_allowed_cidrs — rejects invalid CIDR entries                 ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "ssh_cidrs_rejects_invalid" {
  command = plan

  variables {
    cluster_domain    = "example.com"
    hcloud_api_token  = "mock-token"
    domain            = "test.example.com"
    ssh_allowed_cidrs = ["not-a-cidr"]
  }

  expect_failures = [var.ssh_allowed_cidrs]
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-V13b: k8s_api_allowed_cidrs — rejects empty list                      ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "k8s_api_cidrs_rejects_empty" {
  command = plan

  variables {
    cluster_domain        = "example.com"
    hcloud_api_token      = "mock-token"
    domain                = "test.example.com"
    k8s_api_allowed_cidrs = []
  }

  expect_failures = [var.k8s_api_allowed_cidrs]
}

run "k8s_api_cidrs_rejects_invalid" {
  command = plan

  variables {
    cluster_domain        = "example.com"
    hcloud_api_token      = "mock-token"
    domain                = "test.example.com"
    k8s_api_allowed_cidrs = ["192.168.1.0/24", "garbage"]
  }

  expect_failures = [var.k8s_api_allowed_cidrs]
}
