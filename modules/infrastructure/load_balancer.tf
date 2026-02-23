# ──────────────────────────────────────────────────────────────────────────────
# Load Balancer Architecture: Dual LB (Control Plane + Ingress)
#
# Why two separate LBs instead of one shared LB:
#
# 1. Hetzner Cloud LB does NOT support per-service target groups.
#    All targets receive health checks from ALL services on the LB.
#    With a single LB, workers fail health checks for K8s API (6443) and
#    registration (9345) — they show "yellow" (2/4) in Hetzner console.
#    While traffic routing works correctly (LB only forwards to healthy
#    targets per-service), the false-negative health status defeats
#    monitoring and alerting: "yellow" becomes noise, real failures hide.
#
# 2. DDoS / blast radius isolation. If the public-facing Ingress LB is
#    under attack and saturated, the separate Control Plane LB remains
#    reachable — operators can still `kubectl` into the cluster to
#    mitigate the incident. With a single LB, a web DDoS locks out admin.
#
# 3. Independent scaling & lifecycle. Ingress LB can be upgraded to lb21/lb31
#    under load without touching the control-plane path. Firewall rules differ:
#    API LB should be restricted (VPN/bastion), Ingress LB must be public.
#
# 4. This is the standard pattern used by AWS EKS (NLB for API + ALB for
#    Ingress), GKE (internal LB for API + external for Ingress), and AKS.
#
# Trade-off: +1 lb11 = ~€5.39/month. Acceptable for production workloads
# where operational clarity and security isolation are more important.
#
# Alternative considered — single LB with mixed targets:
#   Cheaper (~€5/month saved), but produces noisy health checks, shared
#   blast radius, and conflated firewall rules. Acceptable only for
#   dev/staging environments.
# ──────────────────────────────────────────────────────────────────────────────

locals {
  # Pre-compute health check parameters once; reused across all LB services.
  # DECISION: Unified health check timing across all services.
  # Why: Simplifies monitoring and makes health check behavior predictable.
  #      Different timings per service would complicate debugging and alerting.
  hc_interval_sec = 15
  hc_timeout_sec  = 10
  hc_retries      = 3

  # Standard lb11 type for both LBs — sufficient for most workloads.
  lb_type = "lb11"

  # Control plane LB service definitions (port → config).
  # DECISION: Define services as a map for clarity and self-documentation.
  cp_services = {
    k8s_api = {
      listen_port      = 6443
      destination_port = 6443
      health_protocol  = "http"
      health_port      = 6443
      http_health = {
        path         = "/healthz"
        tls          = true
        status_codes = ["200", "401"]
      }
    }
    registration = {
      listen_port      = 9345
      destination_port = 9345
      health_protocol  = "tcp"
      health_port      = 9345
      http_health      = null
    }
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  LB-1: Control Plane (K8s API + node registration)                        ║
# ║  Targets: Master nodes only                                               ║
# ║  Ports: 6443 (K8s API), 9345 (RKE2 registration), 22 (SSH, optional)      ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

resource "hcloud_load_balancer" "control_plane" {
  name               = "${var.rke2_cluster_name}-cp-lb"
  load_balancer_type = local.lb_type
  location           = var.load_balancer_location

  labels = {
    "rke2"         = "control-plane"
    "cluster-name" = var.rke2_cluster_name
    "managed-by"   = "opentofu"
  }
}

resource "hcloud_load_balancer_network" "control_plane_network" {
  load_balancer_id = hcloud_load_balancer.control_plane.id
  subnet_id        = hcloud_network_subnet.nodes.id
}

# Initial master target — added immediately after master[0] is created
resource "hcloud_load_balancer_target" "cp_initial_master" {
  load_balancer_id = hcloud_load_balancer.control_plane.id
  type             = "server"
  server_id        = hcloud_server.initial_control_plane[0].id
  use_private_ip   = true

  depends_on = [hcloud_load_balancer_network.control_plane_network]
}

# Additional master targets
resource "hcloud_load_balancer_target" "cp_additional_masters" {
  count = var.control_plane_count > 1 ? var.control_plane_count - 1 : 0

  load_balancer_id = hcloud_load_balancer.control_plane.id
  type             = "server"
  server_id        = hcloud_server.control_plane[count.index].id
  use_private_ip   = true

  depends_on = [hcloud_load_balancer_network.control_plane_network]
}

# K8s API service (6443) — HTTP health check against /healthz
resource "hcloud_load_balancer_service" "cp_k8s_api" {
  load_balancer_id = hcloud_load_balancer.control_plane.id
  protocol         = "tcp"
  listen_port      = local.cp_services.k8s_api.listen_port
  destination_port = local.cp_services.k8s_api.destination_port

  depends_on = [hcloud_load_balancer_target.cp_initial_master]

  health_check {
    protocol = local.cp_services.k8s_api.health_protocol
    port     = local.cp_services.k8s_api.health_port
    interval = local.hc_interval_sec
    timeout  = local.hc_timeout_sec
    retries  = local.hc_retries

    http {
      path         = local.cp_services.k8s_api.http_health.path
      tls          = local.cp_services.k8s_api.http_health.tls
      status_codes = local.cp_services.k8s_api.http_health.status_codes
    }
  }
}

# RKE2 registration service (9345) — used by additional masters and workers
# to join the cluster via the control-plane LB
resource "hcloud_load_balancer_service" "cp_register" {
  load_balancer_id = hcloud_load_balancer.control_plane.id
  protocol         = "tcp"
  listen_port      = local.cp_services.registration.listen_port
  destination_port = local.cp_services.registration.destination_port

  depends_on = [hcloud_load_balancer_target.cp_initial_master]

  health_check {
    protocol = local.cp_services.registration.health_protocol
    port     = local.cp_services.registration.health_port
    interval = local.hc_interval_sec
    timeout  = local.hc_timeout_sec
    retries  = local.hc_retries
  }
}

# SSH via control-plane LB — opt-in, for debugging only
resource "hcloud_load_balancer_service" "cp_ssh" {
  count = var.enable_ssh_on_lb ? 1 : 0

  load_balancer_id = hcloud_load_balancer.control_plane.id
  protocol         = "tcp"
  listen_port      = 22
  destination_port = 22

  depends_on = [hcloud_load_balancer_target.cp_initial_master]

  health_check {
    protocol = "tcp"
    port     = 22
    interval = local.hc_interval_sec
    timeout  = local.hc_timeout_sec
    retries  = local.hc_retries
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  LB-2: Ingress (HTTP/HTTPS application traffic)                           ║
# ║  Targets: Worker nodes only (ingress-nginx DaemonSet with hostPort)        ║
# ║  Ports: 80 (HTTP), 443 (HTTPS), + additional custom ports                 ║
# ║  Created only when harmony.enabled = true (ingress is needed)              ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

resource "hcloud_load_balancer" "ingress" {
  count = var.harmony_enabled ? 1 : 0

  name               = "${var.rke2_cluster_name}-ingress-lb"
  load_balancer_type = local.lb_type
  location           = var.load_balancer_location

  labels = {
    "rke2"         = "ingress"
    "cluster-name" = var.rke2_cluster_name
    "managed-by"   = "opentofu"
  }
}

resource "hcloud_load_balancer_network" "ingress_network" {
  count = var.harmony_enabled ? 1 : 0

  load_balancer_id = hcloud_load_balancer.ingress[0].id
  subnet_id        = hcloud_network_subnet.nodes.id
}

# Worker targets — ingress-nginx runs as DaemonSet with hostPort on workers
resource "hcloud_load_balancer_target" "ingress_workers" {
  count = var.harmony_enabled ? var.agent_node_count : 0

  load_balancer_id = hcloud_load_balancer.ingress[0].id
  type             = "server"
  server_id        = hcloud_server.agent[count.index].id
  use_private_ip   = true

  depends_on = [hcloud_load_balancer_network.ingress_network]
}

# HTTP + HTTPS services — defined as a map to reduce repetition
locals {
  ingress_services = {
    http  = 80
    https = 443
  }
}

resource "hcloud_load_balancer_service" "ingress_http" {
  count = var.harmony_enabled ? 1 : 0

  load_balancer_id = hcloud_load_balancer.ingress[0].id
  protocol         = "tcp"
  listen_port      = local.ingress_services.http
  destination_port = local.ingress_services.http

  depends_on = [hcloud_load_balancer_target.ingress_workers]

  health_check {
    protocol = "tcp"
    port     = local.ingress_services.http
    interval = local.hc_interval_sec
    timeout  = local.hc_timeout_sec
    retries  = local.hc_retries
  }
}

resource "hcloud_load_balancer_service" "ingress_https" {
  count = var.harmony_enabled ? 1 : 0

  load_balancer_id = hcloud_load_balancer.ingress[0].id
  protocol         = "tcp"
  listen_port      = local.ingress_services.https
  destination_port = local.ingress_services.https

  depends_on = [hcloud_load_balancer_target.ingress_workers]

  health_check {
    protocol = "tcp"
    port     = local.ingress_services.https
    interval = local.hc_interval_sec
    timeout  = local.hc_timeout_sec
    retries  = local.hc_retries
  }
}

# Additional custom ports on the ingress LB
resource "hcloud_load_balancer_service" "ingress_custom" {
  for_each = var.harmony_enabled ? toset([for p in var.extra_lb_ports : tostring(p)]) : toset([])

  load_balancer_id = hcloud_load_balancer.ingress[0].id
  protocol         = "tcp"
  listen_port      = tonumber(each.value)
  destination_port = tonumber(each.value)

  depends_on = [hcloud_load_balancer_target.ingress_workers]

  health_check {
    protocol = "tcp"
    port     = tonumber(each.value)
    interval = local.hc_interval_sec
    timeout  = local.hc_timeout_sec
    retries  = local.hc_retries
  }
}
