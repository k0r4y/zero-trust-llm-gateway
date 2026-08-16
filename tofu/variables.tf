variable "tailscale_oauth_id" {
  description = "Tailscale OAuth Client ID"
  type        = string
  sensitive   = true
}

variable "tailscale_oauth_secret" {
  description = "Tailscale OAuth Client Secret"
  type        = string
  sensitive   = true
}

variable "tailnet_name" {
  description = "Your Tailscale tailnet name (e.g. example.github)"
  type        = string
}

variable "ai_server_ip" {
  description = "Tailscale IP of the AI gateway host"
  type        = string
}

variable "mgmt_node_ip" {
  description = "Tailscale IP of the management node for CI SSH"
  type        = string
  default     = "127.0.0.1"
}

variable "k8s_api_ip" {
  description = "Tailscale IP of the Kubernetes API server"
  type        = string
  default     = "127.0.0.1"
}
