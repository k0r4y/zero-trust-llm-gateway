# Zero-Trust Local LLM Gateway

A security-hardened, self-hosted LLM infrastructure running on NVIDIA GPUs via WSL2 and Docker Compose. Features an interactive setup wizard, automated client config generation, and a 20-test integration suite. Gated by Nginx ingress, OpenAI-compatible Bearer authentication via LiteLLM Proxy, and secured over a private Tailscale WireGuard mesh with declarative OpenTofu ACL policies.

---

## 1. Architecture & Topology

```text
 CLIENT TIER (Work Laptop / Remote Devices)
 ┌───────────────────────────────────────────────────────────────────────────┐
 │ Obsidian (Local RAG) │ VS Code (Continue.dev) │ CLI Agent (Aider)       │
 └───────────────────────┬──────────────────────────┴────────────────────────┘
 │ (Tailscale WireGuard Mesh)
 ▼
 ZERO-TRUST NETWORK TIER (Tailscale ACLs)
 ┌───────────────────────────────────────────────────────────────────────────┐
 │ OpenTofu ACL Rule: tag:work-laptop / tag:llm-client -&gt; tcp:80, 443, 11434│
 └───────────────────────┬───────────────────────────────────────────────────┘
 │
 ▼
 GATEWAY & AUTHENTICATION TIER (Docker Network: llm-net)
 ┌───────────────────────────────────────────────────────────────────────────┐
 │ Nginx Ingress (Port 80 / 443 / 11434)                                     │
 │ ├── Location /      ──► Open WebUI Frontend (Chat Interface & Auth DB)  │
 │ ├── Location /v1/   ──► LiteLLM Proxy (Bearer Token Auth & Rate Limiting)│
 │ └── Location /api/  ──► Native Ollama API (Direct model access)           │
 └───────────────────────┬───────────────────────────────────────────────────┘
 │
 ▼
 INFERENCE & GPU COMPUTE TIER (WSL2 / NVIDIA CUDA)
 ┌───────────────────────────────────────────────────────────────────────────┐
 │ Ollama Server (Internal: ollama-server:11434)                             │
 │ ├── deepseek-r1:7b  (Deep Multi-Step Reasoning)                            │
 │ ├── qwen2.5-coder:7b (Code Completion & Agentic Refactoring)              │
 │ └── nomic-embed-text (Dense Vector Embeddings for Local RAG)             │
 └───────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Host Server Setup (Fresh Windows + WSL2)

### Step 2.1: Windows Prerequisites

1. **Install NVIDIA Host Drivers:**  
   Download from [nvidia.com/drivers](https://www.nvidia.com/drivers).  
   *(WSL2 passes GPU compute via the Windows driver — do NOT install a Linux display driver inside WSL2.)*

2. **Enable CPU Virtualization in BIOS:**  
   Turn on **Intel VT-x** or **AMD SVM Mode**.  
   *(If disabled, WSL fails with `0x80370102`.)*

3. **Prevent Windows Sleep:**
   ```powershell
   powercfg /change standby-timeout-ac 0
   powercfg /change hibernate-timeout-ac 0
   ```

4. **Install WSL2 + Ubuntu:**
   ```powershell
   wsl --update
   wsl --install -d Ubuntu
   ```
   Restart when prompted, then launch Ubuntu from Start Menu to create your Linux user.

---

### Step 2.2: Install Docker & NVIDIA Container Toolkit

Open your **WSL2 Ubuntu terminal** and run:

```bash
# Update packages
sudo apt-get update && sudo apt-get install -y curl git jq age python3 python3-pip

# Install Docker Engine
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER

# Install NVIDIA Container Toolkit (required for GPU passthrough)
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker

# Enable systemd for automatic Docker startup
sudo bash -c 'cat &lt;&lt; EOF &gt; /etc/wsl.conf
[boot]
systemd=true
EOF'

# Start Docker
sudo service docker start 2&gt;/dev/null || sudo systemctl start docker

# Verify GPU access inside Docker
docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi
```

---

### Step 2.3: Connect to Tailscale

1. Download Tailscale from [tailscale.com/download](https://tailscale.com/download) (Windows or WSL2).
2. Log in and connect to your Tailnet.
3. Check your assigned IP:
   ```bash
   tailscale ip -4
   ```

---

### Step 2.4: Clone & Run the Interactive Wizard

```bash
git clone https://github.com/k0r4y/zero-trust-llm-gateway.git
cd zero-trust-llm-gateway
./setup.sh
```

The wizard will:
- Validate prerequisites (Docker, GPU, Tailscale, SOPS, Age)
- Guide you through creating a Tailscale OAuth client
- Auto-detect your tailnet name and Tailscale IP
- Let you choose a TLS mode (Plain HTTP / Self-Signed HTTPS / Tailscale HTTPS)
- Recommend model tiers based on your GPU VRAM
- Generate all configs and start the stack
- Create pre-filled client configs in `templates/`

---

## 3. TLS Modes

The wizard lets you choose how clients connect:

| Mode | Use Case | Client URL |
|:---|:---|:---|
| **Plain HTTP** *(Recommended)* | Tailnet-only access. WireGuard encrypts all transit. No cert management. | `http://&lt;TAILSCALE_IP&gt;:11434/v1` |
| **Self-Signed HTTPS** | You want HTTPS semantics inside the tailnet. Browsers show a warning unless you trust the cert. | `https://&lt;TAILSCALE_IP&gt;:443/v1` |
| **Tailscale HTTPS** | Cleanest option. Tailscale provides real certs at `https://&lt;machine&gt;.&lt;tailnet&gt;.ts.net`. | `https://&lt;machine&gt;.&lt;tailnet&gt;.ts.net/v1` |

---

## 4. Daily Operations (Taskfile)

| Command | Purpose |
|:---|:---|
| `task credentials` | Show active URLs, admin email, and masked API token |
| `task up` | Start all containers (decrypts secrets first) |
| `task down` | Stop all containers (preserves volumes) |
| `task ps` | Show container status |
| `task lint` | Run yamllint, compose config check, nginx -t, shellcheck |
| `task test:e2e` | Run the 4-stage integration test harness |
| `task init` | Re-run the interactive wizard |
| `task secrets:encrypt` | Encrypt `compose/.env` → `secrets.enc.yaml` |
| `task secrets:decrypt` | Decrypt `secrets.enc.yaml` → `compose/.env` |
| `task tofu:plan` | Preview Tailscale ACL changes |
| `task tofu:apply` | Apply Tailscale ACL changes |

---

## 5. Client Configuration

After running the wizard, check `templates/` for pre-filled configs. Or run `task credentials` to see your connection details.

### Web Chat Interface
Open your browser to `http://&lt;TAILSCALE_IP&gt;/` and sign in with the admin credentials shown by the wizard.

### VS Code (Continue.dev)
Copy `templates/vscode-continue.json` to your Continue config path:
- **Windows:** `%USERPROFILE%\.continue\config.json`
- **macOS/Linux:** `~/.continue/config.json`

### Obsidian (Smart Connections / Copilot)
Use `templates/obsidian.md` as a reference for base URLs and API keys.

### Aider (Terminal Agent)
```bash
source templates/aider.sh
# Or manually:
export OPENAI_API_BASE="http://&lt;TAILSCALE_IP&gt;:11434/v1"
export OPENAI_API_KEY="&lt;YOUR_TOKEN&gt;"
aider --model openai/qwen2.5-coder:7b
```

---

## 6. Zero-Trust Network (OpenTofu & Tailscale ACLs)

Network policies are managed declaratively in `tofu/`.

### Tag Client Devices
```bash
tailscale up --advertise-tags=tag:work-laptop
```

### Apply ACLs
```bash
task tofu:init   # Download provider
task tofu:plan   # Preview changes
task tofu:apply  # Apply rules live
```

**Enforced behavior:** Tagged devices can only reach ports `80`, `443`, and `11434` on the AI Gateway. All other traffic is dropped at the WireGuard kernel layer.

---

## 7. Security Design

| Feature | Implementation |
|:---|:---|
| **Secrets** | Stored in `compose/.env`, encrypted with SOPS + Age, never committed |
| **API Auth** | Single `LITELLM_MASTER_KEY` for homelab use; per-client virtual keys supported via LiteLLM UI |
| **Network** | Tailscale WireGuard mesh + OpenTofu ACLs for least-privilege access |
| **Images** | Pinned to specific versions (`ollama:0.3.13`, `litellm:main-v1.44.7`, etc.) |
| **TLS** | Three modes available; plain HTTP is safe inside a Tailnet |
| **Admin Seeding** | Wizard auto-creates the admin account before external users can register |
| **Client Configs** | Auto-generated in `templates/` with real tokens; directory is `.gitignore`d |

---

## 8. Troubleshooting

| Issue | Cause | Resolution |
|:---|:---|:---|
| `Error 0x80370102` | CPU virtualization disabled | Enable Intel VT-x / AMD SVM in BIOS |
| `could not select device driver "" with capabilities: [[gpu]]` | Missing NVIDIA Container Toolkit | Re-run Step 2.2 |
| `Cannot connect to the Docker daemon` | Docker not started | `sudo service docker start` |
| `HTTP 401 Unauthorized` | Missing Bearer token | Run `task credentials` to see your token |
| `Connection timed out` | Wrong port or Tailscale ACL | Use `:80` for WebUI, `:11434` for API in plain HTTP mode |
| `SOPS encryption failed` | Missing Age key or `.sops.yaml` | Run `age-keygen -o ~/.age/key.txt` if missing |
| `Open WebUI did not start listening` | Database migration or port conflict | Check logs: `docker compose -f compose/docker-compose.yml logs open-webui` |

---

## 9. Project Structure

```
.
├── compose/
│   ├── docker-compose.yml          # Pinned images, no healthcheck blocks
│   ├── config/
│   │   ├── nginx.conf              # Auto-generated per TLS mode
│   │   └── litellm-config.yaml     # Auto-generated per GPU tier
│   └── .env.example                # Template for manual setup
├── scripts/
│   ├── wizard.py                   # Interactive setup wizard
│   ├── decrypt-env.py              # Robust SOPS → .env converter
│   ├── full-test.sh                # 20-test integration suite
│   ├── test-harness.sh             # 4-stage API validation
│   └── audit-history.sh            # Git history secret scanner
├── templates/                      # Auto-generated client configs (.gitignore'd)
├── tofu/
│   ├── main.tf                     # No hardcoded IPs
│   ├── variables.tf                # Dynamic IP inputs
│   └── terraform.tfvars            # Auto-generated (.gitignore'd)
├── setup.sh                        # 1-click bootstrapper
├── Taskfile.yml                    # All daily operations
├── .sops.yaml                      # SOPS creation rules
└── .gitignore                      # Protects all sensitive files
```

---

## 10. Contributing & Security

- **Never commit `compose/.env`, `secrets.enc.yaml`, or `tofu/terraform.tfvars`.** These are `.gitignore`d.
- **Rotate secrets immediately** if you suspect a leak. The wizard generates new credentials on every run.
- **Run `scripts/audit-history.sh`** before open-sourcing to verify no secrets exist in Git history.
- **Report security issues** via GitHub Issues or email.
