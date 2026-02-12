# Wait for RKE2 API server to become ready on master[0]
resource "null_resource" "wait_for_api" {
  depends_on = [
    hcloud_load_balancer_service.cp_k8s_api,
    hcloud_server.master,
  ]

  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for RKE2 to initialize...'",
      "cloud-init status --wait > /dev/null 2>&1",
      "until /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes >/dev/null 2>&1; do echo 'Waiting for API server...'; sleep 10; done",
      "echo 'RKE2 API server is ready!'",
    ]

    connection {
      type        = "ssh"
      host        = hcloud_server.master[0].ipv4_address
      user        = "root"
      private_key = tls_private_key.machines.private_key_openssh
      timeout     = "10m"
    }
  }
}

data "remote_file" "kubeconfig" {
  depends_on = [
    null_resource.wait_for_api
  ]
  conn {
    host        = hcloud_server.master[0].ipv4_address
    user        = "root"
    private_key = tls_private_key.machines.private_key_openssh
    sudo        = true
    timeout     = 500
  }

  path = "/etc/rancher/rke2/rke2.yaml"
}

data "hcloud_load_balancers" "rke2_control_plane" {
  with_selector = "rke2=control-plane"
}