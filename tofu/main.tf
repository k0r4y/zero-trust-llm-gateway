# Tailscale Zero-Trust Network Policy Definition
provider "tailscale" {
  oauth_client_id     = var.tailscale_oauth_id
  oauth_client_secret = var.tailscale_oauth_secret
  tailnet             = var.tailnet_name
}

resource "tailscale_acl" "network_acl" {
  acl = jsonencode({
    tagOwners = {
      "tag:work-laptop" = ["autogroup:admin"],
      "tag:llm-client"  = ["autogroup:admin"],
      "tag:ai-server"   = ["autogroup:admin"],
      "tag:ci"          = ["autogroup:admin"]
    },
    grants = [
      # Full mesh for members
      {
        src = ["autogroup:member"],
        dst = ["autogroup:member"],
        ip  = ["*"]
      },
      # Least-privilege LLM clients
      {
        src = ["tag:work-laptop", "tag:llm-client"],
        dst = ["tag:ai-server", var.ai_server_ip],
        ip  = ["tcp:443", "tcp:11434"]
      },
      # CI runner access
      {
        src = ["tag:ci"],
        dst = [var.mgmt_node_ip],
        ip  = ["tcp:22"]
      },
      {
        src = ["tag:ci"],
        dst = [var.k8s_api_ip],
        ip  = ["tcp:6443"]
      }
    ]
  })
}
