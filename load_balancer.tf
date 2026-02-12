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

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  LB-1: Control Plane (K8s API + node registration)                        ║
# ║  Targets: Master nodes only                                               ║
# ║  Ports: 6443 (K8s API), 9345 (RKE2 registration), 22 (SSH, optional)      ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

resource "hcloud_load_balancer" "control_plane" {
  name               = "${var.cluster_name}-cp-lb"
  load_balancer_type = "lb11"
  location           = var.lb_location
  labels = {
    "rke2" = "control-plane"
  }
}

resource "hcloud_load_balancer_network" "control_plane_network" {
  load_balancer_id = hcloud_load_balancer.control_plane.id
  subnet_id        = hcloud_network_subnet.main.id
}

# Initial master target — added immediately after master[0] is created
resource "hcloud_load_balancer_target" "cp_initial_master" {
  type             = "server"
  load_balancer_id = hcloud_load_balancer.control_plane.id
  server_id        = hcloud_server.master[0].id
  use_private_ip   = true
  depends_on       = [hcloud_load_balancer_network.control_plane_network]
}

# Additional master targets
resource "hcloud_load_balancer_target" "cp_additional_masters" {
  count            = var.master_node_count > 1 ? var.master_node_count - 1 : 0
  type             = "server"
  load_balancer_id = hcloud_load_balancer.control_plane.id
  server_id        = hcloud_server.additional_masters[count.index].id
  use_private_ip   = true
  depends_on       = [hcloud_load_balancer_network.control_plane_network]
}

# K8s API service (6443) — HTTP health check against /healthz
resource "hcloud_load_balancer_service" "cp_k8s_api" {
  load_balancer_id = hcloud_load_balancer.control_plane.id
  protocol         = "tcp"
  listen_port      = 6443
  destination_port = 6443
  depends_on       = [hcloud_load_balancer_target.cp_initial_master]

  health_check {
    protocol = "http"
    port     = 6443
    interval = 15
    timeout  = 10
    retries  = 3

    http {
      path         = "/healthz"
      tls          = true
      status_codes = ["200", "401"]
    }
  }
}

# RKE2 registration service (9345) — used by additional masters and workers
# to join the cluster via the control-plane LB
resource "hcloud_load_balancer_service" "cp_register" {
  load_balancer_id = hcloud_load_balancer.control_plane.id
  protocol         = "tcp"
  listen_port      = 9345
  destination_port = 9345
  depends_on       = [hcloud_load_balancer_target.cp_initial_master]

  health_check {
    protocol = "tcp"
    port     = 9345
    interval = 15
    timeout  = 10
    retries  = 3
  }
}

# SSH via control-plane LB — opt-in, for debugging only
resource "hcloud_load_balancer_service" "cp_ssh" {
  count            = var.enable_ssh_on_lb ? 1 : 0
  load_balancer_id = hcloud_load_balancer.control_plane.id
  protocol         = "tcp"
  listen_port      = 22
  destination_port = 22
  depends_on       = [hcloud_load_balancer_target.cp_initial_master]

  health_check {
    protocol = "tcp"
    port     = 22
    interval = 15
    timeout  = 10
    retries  = 3
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  LB-2: Ingress (HTTP/HTTPS application traffic)                           ║
# ║  Targets: Worker nodes only (ingress-nginx DaemonSet with hostPort)        ║
# ║  Ports: 80 (HTTP), 443 (HTTPS), + additional custom ports                 ║
# ║  Created only when harmony.enabled = true (ingress is needed)              ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

resource "hcloud_load_balancer" "ingress" {
  count              = var.harmony.enabled ? 1 : 0
  name               = "${var.cluster_name}-ingress-lb"
  load_balancer_type = "lb11"
  location           = var.lb_location
  labels = {
    "rke2" = "ingress"
  }
}

resource "hcloud_load_balancer_network" "ingress_network" {
  count            = var.harmony.enabled ? 1 : 0
  load_balancer_id = hcloud_load_balancer.ingress[0].id
  subnet_id        = hcloud_network_subnet.main.id
}

# Worker targets — ingress-nginx runs as DaemonSet with hostPort on workers
resource "hcloud_load_balancer_target" "ingress_workers" {
  count            = var.harmony.enabled ? var.worker_node_count : 0
  type             = "server"
  load_balancer_id = hcloud_load_balancer.ingress[0].id
  server_id        = hcloud_server.worker[count.index].id
  use_private_ip   = true
  depends_on       = [hcloud_load_balancer_network.ingress_network]
}

# HTTP service (80)
resource "hcloud_load_balancer_service" "ingress_http" {
  count            = var.harmony.enabled ? 1 : 0
  load_balancer_id = hcloud_load_balancer.ingress[0].id
  protocol         = "tcp"
  listen_port      = 80
  destination_port = 80
  depends_on       = [hcloud_load_balancer_target.ingress_workers]

  health_check {
    protocol = "tcp"
    port     = 80
    interval = 15
    timeout  = 10
    retries  = 3
  }
}

# HTTPS service (443)
resource "hcloud_load_balancer_service" "ingress_https" {
  count            = var.harmony.enabled ? 1 : 0
  load_balancer_id = hcloud_load_balancer.ingress[0].id
  protocol         = "tcp"
  listen_port      = 443
  destination_port = 443
  depends_on       = [hcloud_load_balancer_target.ingress_workers]

  health_check {
    protocol = "tcp"
    port     = 443
    interval = 15
    timeout  = 10
    retries  = 3
  }
}

# Additional custom ports on the ingress LB
resource "hcloud_load_balancer_service" "ingress_custom" {
  for_each         = var.harmony.enabled ? toset([for p in var.additional_lb_service_ports : tostring(p)]) : toset([])
  load_balancer_id = hcloud_load_balancer.ingress[0].id
  protocol         = "tcp"
  listen_port      = tonumber(each.value)
  destination_port = tonumber(each.value)
  depends_on       = [hcloud_load_balancer_target.ingress_workers]

  health_check {
    protocol = "tcp"
    port     = tonumber(each.value)
    interval = 15
    timeout  = 10
    retries  = 3
  }
}