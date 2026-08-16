# Tailscale Zero-Trust Network Policy Definition
provider "tailscale" {
  oauth_client_id     = var.tailscale_oauth_id
  oauth_client_secret = var.tailscale_oauth_secret
  tailnet             = var.tailnet_name
}

resource "tailscale_acl" "network_acl" {
  acl = jsonencode({
    # Tag ownership definition: Admins can assign these tags to devices
    tagOwners = {
      # Your personal work laptop
      "tag:work-laptop" = ["autogroup:admin"],
      # Client laptops used by trainees/colleagues
      "tag:llm-client"  = ["autogroup:admin"],
      # Compute host running the local LLM platform
      "tag:ai-server"   = ["autogroup:admin"],
      # GitHub Actions CI runner (from SOC homelab)
      "tag:ci"          = ["autogroup:admin"]
    },

    # Declarative zero-trust access grants (Kernel-level packet filtering)
    grants = [
      # RULE 1: Personal devices (autogroup:member) retain unrestricted peer-to-peer mesh connectivity
      {
        src = ["autogroup:member"],
        dst = ["autogroup:member"],
        ip  = ["*"]
      },

      # RULE 2: Work Laptop & Colleague Isolation (Least Privilege)
      # Restricted STRICTLY to AI Gateway on port 443 (WebUI + API) and 11434 (Legacy API).
      # Cannot reach any other host (mgmt01, node01) or any other port.
      {
        src = ["tag:work-laptop", "tag:llm-client"],
        dst = ["tag:ai-server", "100.107.215.58"],
        ip  = ["tcp:443", "tcp:11434"]
      },

      # RULE 3: Homelab GitHub Actions CI Runner (SSH to mgmt01, k8s API to node01)
      {
        src = ["tag:ci"],
        dst = ["HIDDEN_IP_1"],
        ip  = ["tcp:22"]
      },
      {
        src = ["tag:ci"],
        dst = ["HIDDEN_IP_2"],
        ip  = ["tcp:6443"]
      }
    ]
  })
}
