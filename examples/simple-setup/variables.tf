variable "hcloud_api_token" {
  description = "The API token for Hetzner Cloud authentication."
  type        = string
}

variable "cluster_domain" {
  description = "The base domain name for the Kubernetes cluster."
  type        = string
  default     = "example.com"
}

variable "letsencrypt_issuer" {
  description = "Email address for Let's Encrypt certificate notifications."
  type        = string
  default     = "admin@example.com"
}