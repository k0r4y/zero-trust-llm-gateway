# OpenTofu Provider Constraints
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    # Official Tailscale Terraform Provider
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.17.0"
    }
  }
}
