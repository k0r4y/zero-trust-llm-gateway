# Loop 4: Zero-Trust Network-as-Code (OpenTofu + Tailscale)

### Architectural Decisions & SecOps Takeaways
1. **Declarative Network-as-Code:** Managing Tailscale ACLs via OpenTofu eliminates configuration drift, prevents manual Admin Console errors, and ensures network access policies are peer-reviewed and version-controlled.
2. **Precondition Hash & State Import:** Tailscale protects existing custom ACLs with HTTP 412 checks. Running `tofu import tailscale_acl.network_acl acl` safely incorporates live state without wiping active homelab rules.
3. **Least-Privilege Isolation:** Assigning `tag:work-laptop` or `tag:llm-client` restricts devices at the WireGuard kernel packet-filter layer strictly to ports `443` and `11434` on the AI Gateway.
4. **Automated Credential Injection:** Tailscale OAuth tokens are decrypted in-memory by SOPS and passed as dynamic environment variables (`TF_VAR_*`) to OpenTofu at runtime without writing plaintext tokens to disk.
