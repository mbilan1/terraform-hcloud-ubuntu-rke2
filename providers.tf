terraform {
  required_version = ">= 1.5.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.44"
    }
    remote = {
      source  = "tenstad/remote"
      version = "~> 0.2"
    }
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.19"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.23"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.11"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}

provider "hcloud" {
  token = var.hetzner_token
}

provider "aws" {
  region = var.aws_region

  # When Route53 is not used, supply dummy credentials so the provider
  # initialises without requiring real AWS access.
  access_key = var.route53_zone_id == "" && var.aws_access_key == "" ? "unused" : var.aws_access_key
  secret_key = var.route53_zone_id == "" && var.aws_secret_key == "" ? "unused" : var.aws_secret_key

  skip_credentials_validation = var.route53_zone_id == ""
  skip_requesting_account_id  = var.route53_zone_id == ""
  skip_metadata_api_check     = var.route53_zone_id == ""
}

provider "helm" {
  kubernetes = {
    host = local.cluster_host

    client_certificate     = local.client_cert
    client_key             = local.client_key
    cluster_ca_certificate = local.cluster_ca
  }
}

provider "kubectl" {
  host = local.cluster_host

  client_certificate     = local.client_cert
  client_key             = local.client_key
  cluster_ca_certificate = local.cluster_ca
  load_config_file       = false
}

provider "kubernetes" {
  host = local.cluster_host

  client_certificate     = local.client_cert
  client_key             = local.client_key
  cluster_ca_certificate = local.cluster_ca
}