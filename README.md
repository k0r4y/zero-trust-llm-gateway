# Automated, Zero-Trust Local LLM Platform & Client Gateway

A production-grade, self-hosted Local LLM infrastructure running on NVIDIA GPUs via WSL2 and Docker Compose v2. Gated by a hardened Nginx ingress, standard OpenAI `Authorization: Bearer` authentication via LiteLLM Proxy, and secured over a private Tailscale WireGuard mesh with declarative OpenTofu ACL policies.

---

## 1. Target Architecture & Topology

```text
               CLIENT TIER (Work Laptop / Remote Devices)
 ┌───────────────────────────────────────────────────────────────────────────┐
 │  Obsidian (Local RAG)  │  VS Code (Continue.dev)  │  CLI Agent (Aider)    │
 └───────────────────────┬──────────────────────────┴────────────────────────┘
                         │ (Encrypted WireGuard Mesh: http://<HOST_IP>:443)
                         ▼
        ZERO-TRUST NETWORK TIER (Tailscale ACLs & Host Firewall)
 ┌───────────────────────────────────────────────────────────────────────────┐
 │ OpenTofu ACL Rule: tag:work-laptop / tag:llm-client -> tcp:443, 11434 only│
 └───────────────────────┬───────────────────────────────────────────────────┘
                         │
                         ▼
           GATEWAY & AUTHENTICATION TIER (Docker Network: llm-net)
 ┌───────────────────────────────────────────────────────────────────────────┐
 │ Nginx Ingress (Port 443 / 11434)                                          │
 │   ├── Location /   ──► Open WebUI Frontend (Chat Interface & Auth DB)     │
 │   └── Location /v1 ──► LiteLLM Proxy (Bearer Token Spec & Rate Limiting)  │
 └───────────────────────┬───────────────────────────────────────────────────┘
                         │
                         ▼
             INFERENCE & GPU COMPUTE TIER (WSL2 / NVIDIA CUDA)
 ┌───────────────────────────────────────────────────────────────────────────┐
 │ Ollama Server (Internal Container DNS: ollama-server:11434)               │
 │   ├── deepseek-r1:14b / 7b (Deep Multi-Step Reasoning)                    │
 │   ├── qwen2.5-coder:7b     (Code Completion & Agentic Refactoring)        │
 │   └── nomic-embed-text     (Dense Vector Embeddings for Local RAG)        │
 └───────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Host Server Setup (From a Fresh Windows Install)

Follow these steps on the Windows machine with the NVIDIA GPU that will act as the compute server.

### Step 2.1: Windows Prerequisites & GPU Drivers
1. **Install NVIDIA Drivers:**
   * Download and install the latest **NVIDIA GeForce Game Ready or Studio Driver** from [nvidia.com/drivers](https://www.nvidia.com/drivers).
   * *(WSL2 automatically supports CUDA passthrough using the native Windows NVIDIA driver—do NOT install a separate Linux display driver inside WSL2).*

2. **Prevent Windows Sleep/Hibernation (Compute Host Mode):**
   * Open **PowerShell (as Administrator)** and run:
```powershell
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
```

3. **Install WSL2 (Windows Subsystem for Linux):**
   * In PowerShell (Admin), install Ubuntu:
```powershell
wsl --install -d Ubuntu
```
   * Restart your PC if prompted. When Ubuntu opens, set your Linux username and password.

---

### Step 2.2: Install Docker & Utilities in WSL2
Open your **Ubuntu terminal (WSL2)** and install Docker Engine, Git, and dependencies:

```bash
# 1. Update package lists and install base utilities
sudo apt-get update && sudo apt-get install -y curl git jq age python3 python3-pip

# 2. Install Docker Engine
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER

# 3. Start Docker daemon
sudo service docker start

# 4. Install Taskfile CLI
sh -c "$(curl --location https://taskfile.dev/install.sh)" -- -d -b "$HOME/.local/bin"
echo "export PATH="$HOME/.local/bin:\$PATH"" >> ~/.bashrc
export PATH="$HOME/.local/bin:$PATH"
```

---

### Step 2.3: Install & Connect Tailscale
1. Install Tailscale on your Windows desktop from [tailscale.com/download](https://tailscale.com/download) (or inside WSL2 via `curl -fsSL https://tailscale.com/install.sh | sh`).
2. Log in and connect your machine to your Tailnet.
3. Note your assigned Tailscale IP address (e.g. `100.107.215.58`).

---

### Step 2.4: Clone & 1-Click Bootstrap
In your WSL2 terminal:

```bash
# 1. Clone the repository
git clone https://github.com/k0r4y/llm-platform-iac.git
cd llm-platform-iac

# 2. Run the 1-Click Bootstrap & Hardware Profiler
./setup.sh
```

*(On Windows, you can alternatively double-click **`setup.bat`** from Windows Explorer).*

#### What the Setup Wizard Does Automatically:
* Inspects host GPU VRAM via `nvidia-smi` (or configures CPU fallback mode).
* Generates fresh local API keys and environment variables in `compose/.env`.
* Configures `compose/config/litellm-config.yaml` with recommended models.
* Launches all 4 containers (`ollama-server`, `litellm-proxy`, `open-webui`, `nginx-ingress`).
* Pulls recommended model weights in the background.

---

## 3. Daily Operations & Taskfile Commands

All day-to-day lifecycle tasks are managed via `Taskfile`:

| Command | Purpose |
| :--- | :--- |
| **`task up`** | Decrypts secrets and starts all 4 platform containers in the background. |
| **`task down`** | Safely stops and pauses all stack containers without deleting data. |
| **`task ps`** | Displays container health, status, and uptime. |
| **`task lint`** | Runs 4 automated linters (`yamllint`, `compose config`, `nginx -t`, `shellcheck`). |
| **`task test:e2e`** | Runs the 4-stage automated integration and auth test harness. |
| **`task init`** | Re-runs the interactive hardware profiling wizard to switch model tiers. |

---

## 4. Connecting Client Devices (Work Laptop / Remote)

Once the host server is running, remote devices on the Tailscale network can connect using standard tools.

### Option A: Web Chat Interface (Open WebUI)
Open your browser on your work laptop and navigate to:
👉 **`http://<HOST_TAILSCALE_IP>:443/`**
* Sign in (or create your local admin account on first load).
* Select `deepseek-r1:14b` or `qwen2.5-coder:7b` from the model menu.

---

### Option B: VS Code (Continue.dev Coding Agent)
1. Install the **Continue** extension from the VS Code Marketplace.
2. Open `~/.continue/config.json` (or `%USERPROFILE%\.continue\config.json` on Windows) on your laptop.
3. Paste the following configuration, replacing `<HOST_TAILSCALE_IP>` and `<YOUR_API_TOKEN>`:

```json
{
  "$schema": "https://continue.dev/config.json.schema",
  "models": [
    {
      "title": "Local DeepSeek R1 (Reasoning)",
      "provider": "openai",
      "model": "deepseek-r1:14b",
      "apiBase": "http://<HOST_TAILSCALE_IP>:443/v1",
      "apiKey": "<YOUR_API_TOKEN>"
    },
    {
      "title": "Local Qwen Coder (Fast Coding)",
      "provider": "openai",
      "model": "qwen2.5-coder:7b",
      "apiBase": "http://<HOST_TAILSCALE_IP>:443/v1",
      "apiKey": "<YOUR_API_TOKEN>"
    }
  ],
  "tabAutocompleteModel": {
    "title": "Local Autocomplete",
    "provider": "openai",
    "model": "qwen2.5-coder:7b",
    "apiBase": "http://<HOST_TAILSCALE_IP>:443/v1",
    "apiKey": "<YOUR_API_TOKEN>"
  }
}
```

---

### Option C: Obsidian Notes (Local RAG & Semantic Search)
1. Install **Smart Connections** and/or **Obsidian Copilot** from the Obsidian Community Plugins.
2. **Smart Connections (Vector RAG):**
   * Provider: `Custom / OpenAI Compatible`
   * Base URL: `http://<HOST_TAILSCALE_IP>:443/v1`
   * Embedding Model: `nomic-embed-text`
   * API Key: `<YOUR_API_TOKEN>`
3. **Obsidian Copilot (Chat with Vault):**
   * Base URL: `http://<HOST_TAILSCALE_IP>:443/v1`
   * Model: `deepseek-r1:14b` (or `qwen2.5-coder:7b`)
   * API Key: `<YOUR_API_TOKEN>`

---

### Option D: Terminal Agent (Aider)
Run multi-file terminal refactoring sessions directly against your GPU:

```bash
export OPENAI_API_BASE="http://<HOST_TAILSCALE_IP>:443/v1"
export OPENAI_API_KEY="<YOUR_API_TOKEN>"

# Launch Aider agent targeting local Qwen model
aider --model openai/qwen2.5-coder:7b
```

---

## 5. Zero-Trust Network-as-Code (OpenTofu & Tailscale ACLs)

Tailscale network policies are managed declaratively using **OpenTofu** in `tofu/`.

### 1. Tagging Client Devices for Least Privilege
When colleagues connect their work laptop to the tailnet, tag their machine with `tag:work-laptop` or `tag:llm-client`:
```bash
tailscale up --advertise-tags=tag:work-laptop
```

### 2. Applying ACL Policies
```bash
task tofu:init     # Downloads provider
task tofu:plan     # Previews ACL diffs
task tofu:apply    # Applies zero-trust rules live
```

* **Enforced Behavior:** Tagged devices can **only** reach ports `443` and `11434` on the AI Gateway. All other traffic across the internal network (e.g. SSH, other homelab VMs) is dropped at the WireGuard kernel layer.

---

## 6. Security Architecture & Secrets Management

1. **Zero Raw Port Exposure:** Ollama has zero host-bound ports; it is reachable strictly across the internal Docker bridge (`llm-net`) through LiteLLM.
2. **GitOps Secret Encryption:** Secrets in Git are committed exclusively as `secrets.enc.yaml` encrypted via **Mozilla SOPS + Age** asymmetric keypairs. Raw `.env` files are ignored by Git.
3. **GPU Compute DoS Protection:** Nginx enforces a shared-memory rate-limiting zone (15 req/s with burst buffers) to prevent runaway client loops from crashing GPU VRAM.
4. **SSE Real-Time Streaming:** Ingress reverse proxy uses `proxy_buffering off;` and HTTP/1.1 chunking to stream reasoning and code tokens with zero buffer lag.
