# Automated, Zero-Trust Local LLM Platform & Client Gateway

A production-grade, self-hosted Local LLM infrastructure running on NVIDIA GPUs via WSL2 and Docker Compose v2. Gated by a hardened Nginx ingress, standard OpenAI `Authorization: Bearer` authentication via LiteLLM Proxy, and secured over a private Tailscale WireGuard mesh with declarative OpenTofu ACL policies.

---

## Architecture Overview

```
                                WORK LAPTOP / CLIENTS
        ┌──────────────────────────────────────────────────────────────────┐
        │  VS Code (Continue.dev)  │  Obsidian (Local RAG)  │  Aider Agent │
        └─────────────────────────────────┬────────────────────────────────┘
                                          │ (Encrypted WireGuard Mesh: Port 443)
                                          ▼
                         ZERO-TRUST NETWORK TIER (Tailscale)
        ┌──────────────────────────────────────────────────────────────────┐
        │ OpenTofu ACL Grants: tag:work-laptop -> tcp:443, 11434 only      │
        └─────────────────────────────────┬────────────────────────────────┘
                                          │
                                          ▼
                      UNIFIED INGRESS & AUTH TIER (Docker)
        ┌──────────────────────────────────────────────────────────────────┐
        │ Nginx Ingress (Port 443)                                         │
        │   ├── Location /   ──► Open WebUI Frontend (Chat UI)             │
        │   └── Location /v1 ──► LiteLLM Proxy (Bearer Token & OpenAI Spec)│
        └─────────────────────────────────┬────────────────────────────────┘
                                          │
                                          ▼
                         INFERENCE TIER (NVIDIA CUDA)
        ┌──────────────────────────────────────────────────────────────────┐
        │ Ollama Server (Isolated internal bridge: llm-net)                │
        │   ├── deepseek-r1:14b / 7b  (Deep Reasoning)                     │
        │   ├── qwen2.5-coder:7b      (Code Autocomplete & Agents)         │
        │   └── nomic-embed-text      (Dense Vector Embeddings for RAG)    │
        └──────────────────────────────────────────────────────────────────┘
```

---

## Quickstart (For Host Operators)

### 1. Bootstrap & Hardware Auto-Detection
```bash
git clone git@github.com:k0r4y/llm-platform-iac.git
cd llm-platform-iac

# Run interactive hardware profiling wizard
task init
```

### 2. Common Operations
```bash
task up         # Decrypts secrets and starts stack
task down       # Stops and pauses stack
task lint       # Runs full linters (yamllint, compose config, nginx -t, shellcheck)
task test:e2e   # Runs automated 4-stage integration & auth test harness
```

---

## Client Integration

Ready-to-use client templates are located in `templates/`:
* **VS Code (Continue.dev):** Copy `templates/continue-config.json` into `~/.continue/config.json`.
* **Obsidian RAG:** Follow `templates/obsidian-rag.md` for Smart Connections and Copilot setup.
* **Aider Terminal Agent:** Run `bash templates/aider-env.sh`.

---

## Security & SecOps Architecture
1. **Network Boundary Enforcement:** Ollama exposes zero host ports. All external traffic must route through LiteLLM and Nginx.
2. **GitOps Secrets Management:** Zero plaintext secrets in Git. Secrets are encrypted using Mozilla SOPS and `age` asymmetric keypairs.
3. **Zero-Trust Mesh Networking:** Access to the AI host is managed declaratively via OpenTofu using Tailscale tags (`tag:work-laptop`, `tag:llm-client`).
