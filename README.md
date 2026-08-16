# Automated, Zero-Trust Local LLM Platform & Client Gateway

A production-grade, self-hosted Local LLM infrastructure running on NVIDIA GPUs via WSL2 and Docker Compose v2. Gated by a hardened Nginx ingress, standard OpenAI `Authorization: Bearer` authentication via LiteLLM Proxy, and secured over a private Tailscale WireGuard mesh with declarative OpenTofu ACL policies.

---

## 1. Architecture & Topology

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
1. **Install NVIDIA Host Drivers:**
   * Download and install the latest **NVIDIA GeForce Game Ready or Studio Driver** from [nvidia.com/drivers](https://www.nvidia.com/drivers).
   * *(Note: WSL2 automatically passes GPU compute to Linux via the Windows driver—do NOT install a Linux display driver inside WSL2).*

2. **Verify Hardware Virtualization (BIOS):**
   * Ensure CPU Virtualization (**Intel VT-x** or **AMD SVM Mode**) is enabled in your motherboard BIOS.
   * *(If disabled, WSL will fail with error `0x80370102`).*

3. **Prevent Windows Sleep (Compute Host Mode):**
   * Open **PowerShell (as Administrator)** and run:
```powershell
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
```

4. **Install and Update WSL2:**
   * In PowerShell (Admin), update the WSL store kernel and install Ubuntu:
```powershell
# Update WSL to the latest store kernel (ensures Direct3D/CUDA compute drivers are active)
wsl --update

# Install Ubuntu LTS on WSL2
wsl --install -d Ubuntu
```
   * *(If prompted, restart your PC to finalize hypervisor features, then launch Ubuntu from the Start Menu to create your Linux user account).*

---

### Step 2.2: Install Docker & NVIDIA Container Toolkit in WSL2
Open your **Ubuntu terminal (WSL2)** and execute this one-time setup:

```bash
# 1. Update package lists and install base utilities
sudo apt-get update && sudo apt-get install -y curl git jq age python3 python3-pip

# 2. Install Docker Engine
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER

# 3. Install NVIDIA Container Toolkit (Mandatory for Docker GPU passthrough)
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg   && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list |     sed "s#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g" |     sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker

# 4. Enable systemd in WSL2 for automatic background Docker start (Optional but recommended)
sudo bash -c "cat << EOF > /etc/wsl.conf
[boot]
systemd=true
EOF"

# 5. Start Docker daemon
sudo service docker start 2>/dev/null || sudo systemctl start docker

# 6. Verify GPU access inside Docker
docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi
```

---

### Step 2.3: Connect Host to Tailscale
1. Download and install Tailscale on Windows from [tailscale.com/download](https://tailscale.com/download) (or inside WSL2 via `curl -fsSL https://tailscale.com/install.sh | sh`).
2. Log in and connect your host machine to your Tailnet.
3. Check your assigned Tailscale IP address (e.g., `100.107.215.58`):
```bash
tailscale ip -4
```

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
* Inspects host GPU VRAM via `nvidia-smi` (or configures CPU fallback mode for low-spec hosts).
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
2. Open your Continue configuration:
   * **Windows:** `%USERPROFILE%\.continue\config.json`
   * **macOS / Linux:** `~/.continue/config.json`
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

## 6. Troubleshooting & Common Issues

| Issue / Error | Cause | Resolution |
| :--- | :--- | :--- |
| **`Error 0x80370102` on WSL launch** | CPU Virtualization disabled in BIOS. | Enter motherboard BIOS/UEFI and enable **Intel VT-x** or **AMD SVM Mode**. |
| **`could not select device driver "" with capabilities: [[gpu]]`** | Docker missing NVIDIA Container Toolkit. | Run Step 2.2 commands to install `nvidia-container-toolkit` and restart Docker. |
| **`Cannot connect to the Docker daemon`** | Docker service not started in WSL2. | Run `sudo service docker start` (or enable `systemd=true` in `/etc/wsl.conf`). |
| **`HTTP 401 Unauthorized` on `/v1/models`** | Missing or incorrect Bearer token. | Pass header `-H "Authorization: Bearer <token>"`. Check token in `compose/.env`. |
| **Connection timed out from work laptop** | Tailscale ACL or incorrect port. | Ensure connecting to port `:443` or `:11434` (e.g. `http://100.x.x.x:443/`). Ensure laptop has `tag:work-laptop`. |
| **`failed to decrypt: no matching age key found`** | Fresh clone without host private key. | Run `./setup.sh` or `python3 scripts/wizard.py` to auto-generate fresh local keys. |
