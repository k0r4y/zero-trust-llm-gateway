# Input Variables for Tailscale Provider
variable "tailscale_oauth_id" {
  type        = string
  description = "Tailscale OAuth Client ID for programmatic ACL management"
}

variable "tailscale_oauth_secret" {
  type        = string
  description = "Tailscale OAuth Client Secret"
  sensitive   = true # Prevents secret from being printed in terminal logs
}

variable "tailnet_name" {
  type        = string
  description = "Tailnet name ('-' targets your default account tailnet)"
  default     = "-"
}
