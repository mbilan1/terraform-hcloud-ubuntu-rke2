variable "hcloud_token" {
  description = "The API token for Hetzner Cloud authentication."
  type        = string
  sensitive   = true
}

variable "cluster_domain" {
  description = "The base domain name for the Kubernetes cluster."
  type        = string
  default     = "test.example.com"
}
