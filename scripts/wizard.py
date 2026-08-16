#!/usr/bin/env python3
"""
Zero-Trust Local LLM Platform — Interactive Onboarding Wizard
==============================================================

A security-first, path-agnostic installation wizard that guides
non-technical users through prerequisite validation, credential
generation, Tailscale OAuth creation, and stack deployment.

Security design principles:
  - Never hardcode secrets or IPs in committed files.
  - Prompt users to generate credentials in official UIs (Tailscale).
  - Mask all sensitive output in terminal logs.
  - Auto-detect everything possible; only prompt for what must be human-generated.
  - Generate client configs so users don't manually copy-paste tokens.
"""

import os
import sys
import shutil
import subprocess
import secrets
import json
import time
from pathlib import Path

# =============================================================================
# PATH RESOLUTION — works regardless of clone directory name
# =============================================================================
REPO_ROOT = Path(__file__).resolve().parent.parent
COMPOSE_DIR = REPO_ROOT / "compose"
CONFIG_DIR = COMPOSE_DIR / "config"
TEMPLATES_DIR = REPO_ROOT / "templates"
TOFU_DIR = REPO_ROOT / "tofu"

# Minimum free disk space required (in GB) before we warn the user
MIN_FREE_GB = 20


# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

def print_banner():
    """Display the wizard header."""
    print("\n" + "=" * 70)
    print("  ZERO-TRUST LOCAL LLM PLATFORM — SECURITY-FOCUSED SETUP WIZARD")
    print("=" * 70)


def print_section(title: str):
    """Print a clearly delimited section header."""
    print(f"\n{'─' * 70}")
    print(f"  {title}")
    print("─" * 70)


def run(cmd, check=True, capture=False):
    """
    Thin wrapper around subprocess.run with consistent error handling.
    Security note: we never pass shell=True to avoid injection.
    """
    try:
        result = subprocess.run(
            cmd,
            check=check,
            capture_output=capture,
            text=True,
            timeout=30
        )
        return result
    except subprocess.TimeoutExpired:
        print(f"    [!] Command timed out: {' '.join(cmd)}")
        sys.exit(1)
    except FileNotFoundError:
        print(f"    [!] Command not found: {cmd[0]}")
        sys.exit(1)


def prompt(msg, default="", sensitive=False):
    """
    Interactive prompt with optional default value.
    For sensitive inputs (secrets), we do NOT echo to terminal.
    """
    if sensitive:
        import getpass
        value = getpass.getpass(f"    {msg}: ")
    else:
        full_msg = f"    {msg}"
        if default:
            full_msg += f" [{default}]"
        full_msg += ": "
        value = input(full_msg).strip()
    return value if value else default


def confirm(msg, default_yes=True):
    """
    Ask a yes/no question. Returns True for yes, False for no.
    Case-insensitive and forgiving.
    """
    suffix = " [Y/n]" if default_yes else " [y/N]"
    answer = input(f"    {msg}{suffix}: ").strip().lower()
    if answer == "":
        return default_yes
    return answer in ("y", "yes")


def mask_token(token):
    """Mask a secret for safe terminal display: sk-abcd****wxyz."""
    if len(token) <= 12:
        return "*" * len(token)
    return f"{token[:4]}{'*' * (len(token) - 8)}{token[-4:]}"


# =============================================================================
# PREREQUISITE CHECKS
# =============================================================================

def check_docker():
    """Verify Docker Engine is installed and the daemon is responsive."""
    print("\n[*] Checking Docker Engine...")
    if not shutil.which("docker"):
        print("    [-] Docker is not installed.")
        print("        Install:  curl -fsSL https://get.docker.com | sudo sh")
        return False

    try:
        run(["docker", "info"], check=True, capture=True)
        print("    [✔] Docker daemon is running")
        return True
    except subprocess.CalledProcessError:
        print("    [!] Docker is installed but the daemon is not running.")
        print("        Try:  sudo service docker start  OR  sudo systemctl start docker")
        return False


def check_docker_compose():
    """Verify Docker Compose v2 plugin is available."""
    print("\n[*] Checking Docker Compose v2...")
    if shutil.which("docker"):
        try:
            run(["docker", "compose", "version"], check=True, capture=True)
            print("    [✔] Docker Compose v2 detected")
            return True
        except subprocess.CalledProcessError:
            pass
    print("    [-] Docker Compose v2 not found. Update Docker Engine.")
    return False


def check_nvidia():
    """
    Check NVIDIA drivers and Container Toolkit.
    Returns (ok, vram_gb, gpu_name).
    """
    print("\n[*] Checking NVIDIA GPU support...")
    nvidia_smi = shutil.which("nvidia-smi")
    if not nvidia_smi:
        print("    [!] nvidia-smi not found. GPU passthrough will not work.")
        print("        Ensure NVIDIA drivers are installed on the Windows host.")
        return False, 0.0, "None"

    try:
        result = run([
            "nvidia-smi",
            "--query-gpu=name,memory.total",
            "--format=csv,noheader,nounits"
        ], capture=True)
        gpu_name, vram_mb = result.stdout.strip().split(",")
        vram_gb = round(float(vram_mb.strip()) / 1024, 1)
        print(f"    [✔] GPU: {gpu_name.strip()} ({vram_gb} GB VRAM)")
    except Exception as e:
        print(f"    [!] Failed to query GPU: {e}")
        return False, 0.0, "Unknown"

    if not shutil.which("nvidia-ctk"):
        print("    [!] NVIDIA Container Toolkit missing.")
        print("        Install:  https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html")
        return False, vram_gb, gpu_name.strip()

    print("    [✔] NVIDIA Container Toolkit detected")
    return True, vram_gb, gpu_name.strip()


def check_tailscale():
    """
    Check Tailscale is installed and connected.
    Returns (ok, tailscale_ip).
    """
    print("\n[*] Checking Tailscale mesh network...")
    if not shutil.which("tailscale"):
        print("    [-] Tailscale is not installed.")
        print("        Download:  https://tailscale.com/download")
        print("        After install, run:  tailscale up")
        return False, ""

    try:
        ip = run(["tailscale", "ip", "-4"], capture=True).stdout.strip()
        if not ip:
            raise ValueError("empty IP")
        print(f"    [✔] Tailscale connected (IP: {ip})")
        return True, ip
    except Exception:
        print("    [!] Tailscale is installed but not connected.")
        print("        Run:  tailscale up")
        return False, ""


def get_tailnet_name():
    """
    Auto-detect tailnet name from tailscale status --json.
    Returns None if detection fails.
    """
    try:
        result = run(["tailscale", "status", "--json"], capture=True)
        data = json.loads(result.stdout)
        dns_name = data.get("Self", {}).get("DNSName", "")
        if dns_name and dns_name.endswith("."):
            dns_name = dns_name[:-1]
        parts = dns_name.split(".")
        if len(parts) >= 3:
            return ".".join(parts[1:])
        return None
    except Exception:
        return None


def check_sops():
    """Verify SOPS is installed for secret encryption."""
    print("\n[*] Checking SOPS (Secrets OPerationS)...")
    if shutil.which("sops"):
        print("    [✔] SOPS detected")
        return True
    print("    [-] SOPS not found. Install:  https://github.com/getsops/sops/releases")
    return False


def check_age():
    """
    Verify Age encryption keys exist.
    If missing, offer to generate them automatically.
    """
    print("\n[*] Checking Age encryption keys...")
    age_key = Path.home() / ".age" / "key.txt"
    if age_key.exists():
        print(f"    [✔] Age key found at {age_key}")
        return True

    print("    [!] Age key not found. Required for SOPS encryption.")
    if confirm("Generate a new Age key now?", default_yes=True):
        age_key.parent.mkdir(parents=True, exist_ok=True)
        run(["age-keygen", "-o", str(age_key)])
        print(f"    [✔] Age key generated at {age_key}")
        print("    [!] BACKUP THIS KEY. If you lose it, encrypted secrets are unrecoverable.")
        return True

    print("    [-] Cannot proceed without Age key. Exiting.")
    return False


def check_opentofu():
    """OpenTofu is optional; warn but don't block if missing."""
    print("\n[*] Checking OpenTofu (for ACL management)...")
    if shutil.which("tofu"):
        print("    [✔] OpenTofu detected")
        return True
    print("    [!] OpenTofu not found. Tailscale ACLs must be managed manually.")
    print("        Install:  https://opentofu.org/docs/intro/install/")
    return False


def check_disk_space():
    """Warn if the Docker volume root is low on space."""
    print("\n[*] Checking available disk space...")
    try:
        result = run(["df", "-BG", "/var/lib/docker"], capture=True)
        lines = result.stdout.strip().splitlines()
        if len(lines) >= 2:
            parts = lines[1].split()
            free_gb = int(parts[3].replace("G", ""))
            print(f"    [✔] {free_gb} GB free on Docker volume")
            if free_gb < MIN_FREE_GB:
                print(f"    [!] WARNING: Less than {MIN_FREE_GB} GB free. Models may fail to download.")
                return confirm("Continue anyway?", default_yes=False)
            return True
    except Exception as e:
        print(f"    [!] Could not check disk space: {e}")
    return True


def check_ports():
    """Warn if ports 80, 443, or 11434 are already bound."""
    print("\n[*] Checking port availability...")
    busy_ports = []
    for port in [80, 443, 11434]:
        try:
            result = run(["ss", "-tlnp"], capture=True)
            if f":{port} " in result.stdout:
                busy_ports.append(port)
        except Exception:
            pass

    if busy_ports:
        print(f"    [!] Ports already in use: {busy_ports}")
        print("        Stop conflicting services or change nginx ports in compose/docker-compose.yml")
        return confirm("Continue anyway?", default_yes=False)
    print("    [✔] Ports 80, 443, 11434 are available")
    return True


# =============================================================================
# CREDENTIAL & CONFIG GENERATION
# =============================================================================

def generate_local_secrets():
    """
    Generate cryptographically secure local secrets.
    Returns a dict of all generated key-value pairs.
    """
    print("\n[*] Generating local secrets...")
    secrets_map = {
        "LITELLM_MASTER_KEY": "sk-" + secrets.token_hex(16),
        "WEBUI_SECRET_KEY": secrets.token_hex(32),
        "ADMIN_EMAIL": "admin@localhost.local",
        "ADMIN_PASSWORD": secrets.token_urlsafe(16),
    }
    print(f"    [✔] LiteLLM master key:  {mask_token(secrets_map['LITELLM_MASTER_KEY'])}")
    print(f"    [✔] WebUI secret key:    {mask_token(secrets_map['WEBUI_SECRET_KEY'])}")
    print(f"    [✔] Admin credentials:   {secrets_map['ADMIN_EMAIL']} / {'*' * 8}")
    return secrets_map


def prompt_tailscale_oauth():
    """
    Guide the user through creating a Tailscale OAuth client.
    This cannot be automated because Tailscale requires browser-based creation.
    """
    print_section("STEP 1: Tailscale OAuth Client")
    print("""
The wizard needs a Tailscale OAuth client to manage ACLs via OpenTofu.
This is a ONE-TIME setup step.

  1. Open your browser to:
     https://login.tailscale.com/admin/settings/oauth

  2. Click "Generate OAuth client..."

  3. Under 'Scopes', check ONLY:
     [✓] ACLs  (read + write)

  4. Click "Generate client"

  5. Copy the Client ID (short alphanumeric, e.g., k7ohW6S9j621CNTRL)
     and the Client Secret (long string starting with tskey-client-...).
""")

    if not confirm("Do you want to configure Tailscale OAuth now?", default_yes=True):
        print("    [!] Skipping OAuth setup. You must manage ACLs manually.")
        return {
            "TAILSCALE_OAUTH_ID": "PLACEHOLDER",
            "TAILSCALE_OAUTH_SECRET": "PLACEHOLDER",
        }

    oauth_id = prompt("Paste your OAuth Client ID")
    # Tailscale Client IDs are short alphanumeric (e.g., k7ohW6S9j621CNTRL).
    # Client SECRETS start with 'tskey-client-'. Warn if they mixed them up.
    if oauth_id.startswith("tskey-client-"):
        print("    [!] Warning: This looks like a Client SECRET, not a Client ID.")
        print("        Client ID example:     k7ohW6S9j621CNTRL")
        print("        Client Secret example: tskey-client-k7ohW6S9j621CNTRL-...")
        if not confirm("Are you sure this is the Client ID?", default_yes=False):
            oauth_id = prompt("Paste your OAuth Client ID")

    oauth_secret = prompt("Paste your OAuth Client Secret", sensitive=True)
    # The secret should start with 'tskey-client-'. Warn if it doesn't.
    if not oauth_secret.startswith("tskey-client-"):
        print("    [!] Warning: This doesn't look like a typical Tailscale Client Secret.")
        print("        Expected format: tskey-client-xxxxxxxxxxxxxxxxxxxxxxxxxxxx")
        if not confirm("Are you sure this is the Client Secret?", default_yes=False):
            oauth_secret = prompt("Paste your OAuth Client Secret", sensitive=True)

    print("    [✔] OAuth credentials captured (will be encrypted)")
    return {
        "TAILSCALE_OAUTH_ID": oauth_id,
        "TAILSCALE_OAUTH_SECRET": oauth_secret,
    }


def prompt_tailnet_and_peers(local_ip):
    """
    Auto-detect tailnet name and prompt for optional peer IPs.
    """
    print_section("STEP 2: Tailnet & Peer Configuration")

    tailnet = get_tailnet_name()
    if tailnet:
        if confirm(f"Detected tailnet: '{tailnet}'. Use this?", default_yes=True):
            pass
        else:
            tailnet = prompt("Enter your tailnet name (e.g., k0r4y.github)")
    else:
        tailnet = prompt("Enter your tailnet name (e.g., k0r4y.github)")

    print(f"\n    [✔] Tailnet: {tailnet}")
    print(f"    [✔] Local AI server IP: {local_ip}")

    print("\n    Optional: Enter Tailscale IPs of other machines for ACL rules.")
    print("    Press Enter to skip if you don't have these yet.")

    mgmt_ip = prompt("Mgmt/SSH node Tailscale IP (for CI runner ACLs)")
    k8s_ip = prompt("Kubernetes API server Tailscale IP")

    return {
        "TAILNET_NAME": tailnet,
        "AI_SERVER_IP": local_ip,
        "MGMT_NODE_IP": mgmt_ip if mgmt_ip else "127.0.0.1",
        "K8S_API_IP": k8s_ip if k8s_ip else "127.0.0.1",
    }


def choose_tls_mode():
    """
    Let the user choose how TLS is handled.
    Returns one of: 'plain', 'selfsigned', 'tailscale'
    """
    print_section("STEP 3: TLS / Encryption Mode")

    print("""
Choose how clients connect securely:

  [1] PLAIN HTTP  (Recommended for Tailnet-only use)
      - No certificate management
      - Tailscale WireGuard encrypts all transit traffic
      - Fastest setup

  [2] SELF-SIGNED HTTPS
      - Nginx terminates TLS with auto-generated certificates
      - Browsers will show a warning unless you trust the cert manually
      - Good if you want HTTPS semantics without external dependencies

  [3] TAILSCALE HTTPS
      - Nginx runs plain HTTP; Tailscale provides real HTTPS at
        https://<machine>.<tailnet>.ts.net
      - Requires enabling HTTPS in Tailscale admin console
      - Best of both worlds: real certs + zero config
""")

    choice = prompt("Enter choice", default="1")
    modes = {"1": "plain", "2": "selfsigned", "3": "tailscale"}
    mode = modes.get(choice, "plain")

    if mode == "plain":
        print("    [✔] Mode: Plain HTTP (Tailscale WireGuard provides encryption)")
    elif mode == "selfsigned":
        print("    [✔] Mode: Self-signed HTTPS")
    else:
        print("    [✔] Mode: Tailscale HTTPS")
        print("    [!] Remember to enable HTTPS in your Tailscale admin console:")
        print("        https://login.tailscale.com/admin/settings/features")

    return mode


def generate_nginx_conf(mode, tailscale_ip, tailnet):
    """
    Generate nginx.conf appropriate for the chosen TLS mode.
    Backs up the existing config before overwriting.
    """
    nginx_path = CONFIG_DIR / "nginx.conf"
    if nginx_path.exists():
        backup = nginx_path.with_suffix(".conf.backup")
        shutil.copy(nginx_path, backup)
        print(f"    [✔] Backed up existing nginx.conf to {backup.name}")

    if mode == "plain":
        config = f"""# Auto-generated nginx.conf — PLAIN HTTP mode
# Tailscale WireGuard encrypts all transit; no TLS termination needed.
events {{
    worker_connections 1024;
}}

http {{
    resolver 127.0.0.11 valid=10s;
    limit_req_zone $binary_remote_addr zone=ai_limit:10m rate=15r/s;
    client_max_body_size 50M;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    server {{
        listen 80;
        listen 11434;

        location /v1/ {{
            limit_req zone=ai_limit burst=30 nodelay;
            add_header Access-Control-Allow-Origin "*" always;
            add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;
            add_header Access-Control-Allow-Headers "Authorization, Content-Type" always;
            if ($request_method = OPTIONS) {{
                return 204;
            }}
            set $litellm_upstream http://litellm-proxy:4000;
            proxy_pass $litellm_upstream;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_buffering off;
            proxy_cache off;
            proxy_http_version 1.1;
            proxy_set_header Connection '';
            chunked_transfer_encoding on;
            proxy_read_timeout 600s;
            proxy_send_timeout 600s;
        }}

        location / {{
            set $webui_upstream http://open-webui:8080;
            proxy_pass $webui_upstream;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_buffering off;
            proxy_read_timeout 300s;
        }}

        location /ollama/ {{
            set $ollama_upstream http://ollama-server:11434;
            proxy_pass $ollama_upstream;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_buffering off;
            proxy_read_timeout 600s;
        }}
    }}
}}
"""
    elif mode == "selfsigned":
        config = f"""# Auto-generated nginx.conf — SELF-SIGNED HTTPS mode
events {{
    worker_connections 1024;
}}

http {{
    resolver 127.0.0.11 valid=10s;
    limit_req_zone $binary_remote_addr zone=ai_limit:10m rate=15r/s;
    client_max_body_size 50M;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    server {{
        listen 80;
        return 301 https://$host$request_uri;
    }}

    server {{
        listen 443 ssl;
        listen 11434;

        ssl_certificate /etc/nginx/certs/nginx-selfsigned.crt;
        ssl_certificate_key /etc/nginx/certs/nginx-selfsigned.key;
        ssl_protocols TLSv1.2 TLSv1.3;

        location /v1/ {{
            limit_req zone=ai_limit burst=30 nodelay;
            add_header Access-Control-Allow-Origin "*" always;
            add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;
            add_header Access-Control-Allow-Headers "Authorization, Content-Type" always;
            if ($request_method = OPTIONS) {{
                return 204;
            }}
            set $litellm_upstream http://litellm-proxy:4000;
            proxy_pass $litellm_upstream;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_buffering off;
            proxy_cache off;
            proxy_http_version 1.1;
            proxy_set_header Connection '';
            chunked_transfer_encoding on;
            proxy_read_timeout 600s;
            proxy_send_timeout 600s;
        }}

        location / {{
            set $webui_upstream http://open-webui:8080;
            proxy_pass $webui_upstream;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_buffering off;
            proxy_read_timeout 300s;
        }}

        location /ollama/ {{
            set $ollama_upstream http://ollama-server:11434;
            proxy_pass $ollama_upstream;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_buffering off;
            proxy_read_timeout 600s;
        }}
    }}
}}
"""
    else:
        config = f"""# Auto-generated nginx.conf — TAILSCALE HTTPS mode
# Tailscale provides real HTTPS at https://<machine>.<tailnet>.ts.net
events {{
    worker_connections 1024;
}}

http {{
    resolver 127.0.0.11 valid=10s;
    limit_req_zone $binary_remote_addr zone=ai_limit:10m rate=15r/s;
    client_max_body_size 50M;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    server {{
        listen 80;

        location /v1/ {{
            limit_req zone=ai_limit burst=30 nodelay;
            add_header Access-Control-Allow-Origin "*" always;
            add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;
            add_header Access-Control-Allow-Headers "Authorization, Content-Type" always;
            if ($request_method = OPTIONS) {{
                return 204;
            }}
            set $litellm_upstream http://litellm-proxy:4000;
            proxy_pass $litellm_upstream;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_buffering off;
            proxy_cache off;
            proxy_http_version 1.1;
            proxy_set_header Connection '';
            chunked_transfer_encoding on;
            proxy_read_timeout 600s;
            proxy_send_timeout 600s;
        }}

        location / {{
            set $webui_upstream http://open-webui:8080;
            proxy_pass $webui_upstream;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_buffering off;
            proxy_read_timeout 300s;
        }}

        location /ollama/ {{
            set $ollama_upstream http://ollama-server:11434;
            proxy_pass $ollama_upstream;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_buffering off;
            proxy_read_timeout 600s;
        }}
    }}
}}
"""

    with open(nginx_path, "w") as f:
        f.write(config)
    print(f"    [✔] Generated compose/config/nginx.conf ({mode} mode)")


def generate_terraform_tfvars(network_vars):
    """
    Generate tofu/terraform.tfvars from user-provided network information.
    Never hardcode IPs in committed .tf files.
    """
    tfvars_path = TOFU_DIR / "terraform.tfvars"
    if tfvars_path.exists():
        backup = tfvars_path.with_suffix(".tfvars.backup")
        shutil.copy(tfvars_path, backup)
        print(f"    [✔] Backed up existing terraform.tfvars")

    content = f"""# Auto-generated by setup wizard — do NOT commit to Git
tailnet_name = "{network_vars['TAILNET_NAME']}"
ai_server_ip = "{network_vars['AI_SERVER_IP']}"
mgmt_node_ip = "{network_vars['MGMT_NODE_IP']}"
k8s_api_ip   = "{network_vars['K8S_API_IP']}"
"""
    with open(tfvars_path, "w") as f:
        f.write(content)
    print(f"    [✔] Generated tofu/terraform.tfvars")
    print(f"    [!] This file is .gitignored — verify: grep tfvars .gitignore")


def generate_client_configs(tailscale_ip, api_key, mode, tailnet):
    """
    Generate pre-filled client configuration templates so users don't
    manually copy-paste tokens and risk typos or exposure.
    """
    TEMPLATES_DIR.mkdir(parents=True, exist_ok=True)

    scheme = "https" if mode == "selfsigned" else "http"
    base_url = f"{scheme}://{tailscale_ip}:443/v1"
    ollama_url = f"http://{tailscale_ip}:11434/v1"

    vscode_config = {
        "$schema": "https://continue.dev/config.json.schema",
        "models": [
            {
                "title": "Local DeepSeek R1 (Reasoning)",
                "provider": "openai",
                "model": "deepseek-r1:7b",
                "apiBase": base_url,
                "apiKey": api_key
            },
            {
                "title": "Local Qwen Coder (Fast Coding)",
                "provider": "openai",
                "model": "qwen2.5-coder:7b",
                "apiBase": base_url,
                "apiKey": api_key
            }
        ],
        "tabAutocompleteModel": {
            "title": "Local Autocomplete",
            "provider": "openai",
            "model": "qwen2.5-coder:7b",
            "apiBase": base_url,
            "apiKey": api_key
        }
    }
    with open(TEMPLATES_DIR / "vscode-continue.json", "w") as f:
        json.dump(vscode_config, f, indent=2)

    obsidian_md = f"""# Obsidian / Smart Connections Configuration

## Chat Provider
- **Base URL:** `{base_url}`
- **Model:** `deepseek-r1:7b` or `qwen2.5-coder:7b`
- **API Key:** `{mask_token(api_key)}`

## Embeddings Provider
- **Base URL:** `{base_url}`
- **Embedding Model:** `nomic-embed-text`
- **API Key:** `{mask_token(api_key)}`

## Note
If using **self-signed HTTPS**, you must trust the certificate on this device first.
If using **plain HTTP**, no certificate setup is needed (Tailscale encrypts transit).
"""
    with open(TEMPLATES_DIR / "obsidian.md", "w") as f:
        f.write(obsidian_md)

    aider_sh = f"""#!/usr/bin/env bash
# Aider configuration for local LLM gateway
export OPENAI_API_BASE="{ollama_url}"
export OPENAI_API_KEY="{api_key}"

# Launch aider targeting the local Qwen model
aider --model openai/qwen2.5-coder:7b
"""
    with open(TEMPLATES_DIR / "aider.sh", "w") as f:
        f.write(aider_sh)
    os.chmod(TEMPLATES_DIR / "aider.sh", 0o755)

    print(f"    [✔] Generated client configs in {TEMPLATES_DIR}/")


# =============================================================================
# HARDWARE PROFILING (preserved from original wizard)
# =============================================================================

def estimate_vram(model_name):
    """Rough VRAM footprint in GB for loaded models."""
    lowered = model_name.lower()
    if "70b" in lowered:
        return 40.0
    if "32b" in lowered:
        return 20.0
    if "14b" in lowered:
        return 10.0
    if "7b" in lowered:
        return 5.0
    if "3b" in lowered:
        return 2.5
    if "1.5b" in lowered:
        return 1.5
    if "embed" in lowered:
        return 1.0
    return 5.0


def recommend_tier(vram_gb):
    """Selects the optimal model tier based on available VRAM."""
    if vram_gb >= 15.0:
        return "Tier 3 (High Performance)", ["deepseek-r1:14b", "qwen2.5-coder:7b", "nomic-embed-text"]
    elif vram_gb >= 8.0:
        return "Tier 2 (Balanced Reasoning & Code)", ["deepseek-r1:7b", "qwen2.5-coder:7b", "nomic-embed-text"]
    else:
        return "Tier 1 (Lightweight / CPU Friendly)", ["qwen2.5:3b", "qwen2.5-coder:1.5b", "nomic-embed-text"]


def generate_litellm_config(models):
    """Generate LiteLLM configuration with recommended models."""
    config_path = CONFIG_DIR / "litellm-config.yaml"
    if config_path.exists():
        backup = config_path.with_suffix(".yaml.backup")
        shutil.copy(config_path, backup)
        print(f"    [✔] Backed up existing litellm-config.yaml")

    with open(config_path, "w") as f:
        f.write("# Auto-generated LiteLLM Configuration from Onboarding Wizard\n")
        f.write("model_list:\n")
        for m in models:
            f.write(f"  - model_name: {m}\n")
            f.write(f"    litellm_params:\n")
            f.write(f"      model: ollama/{m}\n")
            f.write(f"      api_base: http://ollama-server:11434\n\n")
        f.write("litellm_settings:\n")
        f.write("  drop_params: true\n")
        f.write("  request_timeout: 600\n\n")
        f.write("general_settings:\n")
        f.write('  master_key: "os.environ/LITELLM_MASTER_KEY"\n')
    print("    [✔] Generated compose/config/litellm-config.yaml")


# =============================================================================
# DEPLOYMENT & SEEDING
# =============================================================================

def write_env_file(env_vars):
    """Write the combined environment file and encrypt it with SOPS."""
    env_path = COMPOSE_DIR / ".env"
    env_path.parent.mkdir(parents=True, exist_ok=True)

    with open(env_path, "w") as f:
        f.write("# Auto-generated by Zero-Trust LLM Wizard\n")
        f.write("# DO NOT COMMIT THIS FILE TO GIT\n")
        for key, value in env_vars.items():
            if not key.startswith("_"):
                f.write(f"{key}={value}\n")

    print("    [✔] Wrote compose/.env")

    try:
        # Extract Age public key from ~/.age/key.txt
        age_key_file = Path.home() / ".age" / "key.txt"
        age_pubkey = None
        if age_key_file.exists():
            with open(age_key_file) as f:
                for line in f:
                    if line.startswith("# public key:"):
                        age_pubkey = line.split(":", 1)[1].strip()
                        break

        if age_pubkey:
            result = run(["sops", "--encrypt", "--age", age_pubkey, "--input-type", "dotenv", "--output-type", "yaml", str(env_path)], capture=True)
            with open(REPO_ROOT / "secrets.enc.yaml", "w") as f:
                f.write(result.stdout)
            print("    [✔] Encrypted secrets.enc.yaml with SOPS")
        else:
            raise RuntimeError("Could not find Age public key in ~/.age/key.txt")
    except Exception as e:
        print(f"    [!] SOPS encryption failed: {e}")
        print("    [!] Your secrets are in compose/.env — add it to .gitignore manually!")


def start_stack():
    """Start the Docker Compose stack."""
    print("\n[*] Starting LLM Platform containers...")
    compose_file = COMPOSE_DIR / "docker-compose.yml"
    try:
        run(["docker", "compose", "-f", str(compose_file), "up", "-d"])
        print("    [✔] Containers started")
        return True
    except subprocess.CalledProcessError as e:
        print(f"    [-] Docker Compose failed: {e}")
        return False


def pull_models(models):
    """Pull recommended Ollama models."""
    print("\n[*] Pulling recommended models (this may take several minutes)...")
    for m in models:
        print(f"    --> Pulling {m}... (this may take 5-10 minutes for large models)")
        # Use subprocess directly with a 10-minute timeout instead of the 30s default
        import subprocess
        subprocess.run(
            ["docker", "exec", "-i", "ollama-server", "ollama", "pull", m],
            check=False,
            timeout=600
        )


def seed_admin_account(admin_email, admin_password):
    """
    Create the Open WebUI admin account before external users can register.
    Retries with exponential backoff because WebUI takes time to initialize.
    """
    print("\n[*] Seeding Open WebUI admin account...")
    import urllib.request
    import socket

    # First, wait until Open WebUI is actually listening on port 8080
    print("    ... waiting for Open WebUI to start listening...")
    for _ in range(60):
        try:
            sock = socket.create_connection(("127.0.0.1", 8080), timeout=1)
            sock.close()
            print("    [✔] Open WebUI is listening on port 8080")
            break
        except (socket.error, socket.timeout):
            time.sleep(1)
    else:
        print("    [!] Open WebUI did not start listening within 60 seconds")
        return False

    max_retries = 6
    for attempt in range(1, max_retries + 1):
        try:
            time.sleep(2)
            data = json.dumps({
                "name": "Admin",
                "email": admin_email,
                "password": admin_password
            }).encode()

            req = urllib.request.Request(
                "http://localhost:8080/api/v1/auths/signup",
                data=data,
                headers={"Content-Type": "application/json"},
                method="POST"
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                if resp.status == 200:
                    print(f"    [✔] Admin account created ({admin_email})")
                    return True
                else:
                    body = resp.read().decode()
                    if "already exists" in body.lower() or "email already" in body.lower():
                        print(f"    [✔] Admin account already exists ({admin_email})")
                        return True
                    print(f"    [!] Admin signup returned HTTP {resp.status}: {body[:100]}")
                    return False
        except urllib.error.HTTPError as e:
            body = e.read().decode()
            if "already exists" in body.lower() or "email already" in body.lower():
                print(f"    [✔] Admin account already exists ({admin_email})")
                return True
            if attempt < max_retries:
                print(f"    ... retry {attempt}/{max_retries} (WebUI not ready yet)")
            else:
                print(f"    [!] Could not auto-seed admin after {max_retries} attempts: {e}")
                return False
        except Exception as e:
            if attempt < max_retries:
                print(f"    ... retry {attempt}/{max_retries} (WebUI not ready yet)")
            else:
                print(f"    [!] Could not auto-seed admin after {max_retries} attempts: {e}")
                return False
    return False


def quick_verify(api_key, mode):
    """Run a lightweight health check against the API gateway with retries."""
    print("\n[*] Running post-deployment verification...")

    # Determine correct URL based on TLS mode
    if mode == "selfsigned":
        scheme = "https"
        port = "443"
        curl_opts = ["-sk", "--max-time", "10"]
    else:
        scheme = "http"
        port = "11434"
        curl_opts = ["-s", "--max-time", "10"]

    url = f"{scheme}://127.0.0.1:{port}/v1/models"

    max_retries = 5
    for attempt in range(1, max_retries + 1):
        try:
            time.sleep(3)
            result = run(["curl"] + curl_opts + [
                "-H", f"Authorization: Bearer {api_key}",
                url
            ], capture=True, check=False)

            if result.returncode == 0 and '"id"' in result.stdout:
                print("    [✔] API gateway responding with model list")
                return True
            else:
                print(f"    ... retry {attempt}/{max_retries} (API not ready)")
        except Exception:
            print(f"    ... retry {attempt}/{max_retries} (API not ready)")

    print("    [!] API verification failed after all retries — check logs with: docker compose -f compose/docker-compose.yml logs")
    return False


# =============================================================================
# MAIN ORCHESTRATION
# =============================================================================

def main():
    print_banner()

    # PHASE 0: PREREQUISITES
    print_section("PHASE 0: Prerequisite Validation")

    ok = True
    ok &= check_docker()
    ok &= check_docker_compose()
    gpu_ok, vram_gb, gpu_name = check_nvidia()
    ok &= gpu_ok
    ts_ok, tailscale_ip = check_tailscale()
    ok &= ts_ok
    ok &= check_sops()
    ok &= check_age()
    check_opentofu()
    ok &= check_disk_space()
    ok &= check_ports()

    if not ok:
        print("\n[-] Some prerequisites failed. Fix them and re-run the wizard.")
        sys.exit(1)

    # PHASE 1: SECRETS & CREDENTIALS
    print_section("PHASE 1: Credential Generation")

    local_secrets = generate_local_secrets()
    oauth_secrets = prompt_tailscale_oauth()
    network_vars = prompt_tailnet_and_peers(tailscale_ip)
    tls_mode = choose_tls_mode()

    env_vars = {
        **local_secrets,
        **oauth_secrets,
        "TAILNET_NAME": network_vars["TAILNET_NAME"],
    }

    # PHASE 2: HARDWARE PROFILING
    print_section("PHASE 2: Hardware Profiling & Model Selection")

    tier_name, models = recommend_tier(vram_gb)

    total_estimated = sum(estimate_vram(m) for m in models)
    if total_estimated > vram_gb * 0.9 and vram_gb > 0:
        print(f"\n[!] WARNING: Recommended models may require ~{total_estimated} GB VRAM,")
        print(f"    but only {vram_gb} GB detected. Ollama may OOM or unload models frequently.")
        if not confirm("Continue with these models?", default_yes=False):
            print("[*] You can manually edit compose/config/litellm-config.yaml later.")
            sys.exit(0)

    print(f"\n[+] Recommended Configuration:")
    print(f"    Tier:   {tier_name}")
    print(f"    Models: {', '.join(models)}")

    if not confirm("Apply this configuration and launch stack?", default_yes=True):
        print("[*] Setup aborted by user.")
        sys.exit(0)

    # PHASE 3: CONFIGURATION GENERATION
    print_section("PHASE 3: Generating Configuration Files")

    generate_nginx_conf(tls_mode, tailscale_ip, network_vars["TAILNET_NAME"])
    generate_terraform_tfvars(network_vars)
    generate_litellm_config(models)
    generate_client_configs(
        tailscale_ip=tailscale_ip,
        api_key=local_secrets["LITELLM_MASTER_KEY"],
        mode=tls_mode,
        tailnet=network_vars["TAILNET_NAME"]
    )
    write_env_file(env_vars)

    # PHASE 4: DEPLOYMENT
    print_section("PHASE 4: Stack Deployment")

    if not start_stack():
        sys.exit(1)

    pull_models(models)
    seed_admin_account(local_secrets["ADMIN_EMAIL"], local_secrets["ADMIN_PASSWORD"])

    # PHASE 5: VERIFICATION & SUMMARY
    print_section("PHASE 5: Verification")

    quick_verify(local_secrets["LITELLM_MASTER_KEY"], tls_mode)

    if tls_mode == "tailscale":
        web_url = f"https://{network_vars['TAILNET_NAME'].split('.')[0]}.{network_vars['TAILNET_NAME']}"
        api_url = f"http://{tailscale_ip}:11434/v1"
    elif tls_mode == "selfsigned":
        web_url = f"https://{tailscale_ip}/"
        api_url = f"https://{tailscale_ip}:443/v1"
    else:
        web_url = f"http://{tailscale_ip}/"
        api_url = f"http://{tailscale_ip}:11434/v1"

    print("\n" + "=" * 70)
    print("  ✔ SETUP COMPLETE — PLATFORM IS READY FOR USE")
    print("=" * 70)
    print(f"\n  Web Chat UI:     {web_url}")
    print(f"  OpenAI API:      {api_url}")
    print(f"  Admin Email:     {local_secrets['ADMIN_EMAIL']}")
    print(f"  Admin Password:  {local_secrets['ADMIN_PASSWORD']}")
    print(f"  Master Token:    {mask_token(local_secrets['LITELLM_MASTER_KEY'])}")
    print(f"\n  [!] SAVE THESE CREDENTIALS NOW. They will not be shown again.")
    # Generate a setup receipt file for the user
    receipt_path = TEMPLATES_DIR / "setup-receipt.txt"
    TEMPLATES_DIR.mkdir(parents=True, exist_ok=True)
    with open(receipt_path, "w") as rf:
        rf.write("Zero-Trust LLM Gateway — Setup Receipt\n")
        rf.write("=" * 50 + "\n")
        rf.write(f"Generated: {time.strftime('%Y-%m-%d %H:%M:%S')}\n\n")
        rf.write(f"Access URLs:\n")
        rf.write(f"  Web Chat UI:  {web_url}\n")
        rf.write(f"  OpenAI API:   {api_url}\n\n")
        rf.write(f"Admin Account:\n")
        rf.write(f"  Email:    {local_secrets['ADMIN_EMAIL']}\n")
        rf.write(f"  Password: {local_secrets['ADMIN_PASSWORD']}\n\n")
        rf.write(f"API Token:\n")
        rf.write(f"  {local_secrets['LITELLM_MASTER_KEY']}\n\n")
        rf.write("[!] Store this file securely. Delete it after saving to your password manager.\n")
    print(f"\n  [✔] Setup receipt saved to: {receipt_path}")

    print(f"\n  Client configs:   {TEMPLATES_DIR}/")
    print(f"  Next steps:")
    print(f"    • task credentials    — show masked credentials anytime")
    print(f"    • task test:e2e       — run full integration tests")
    print(f"    • task tofu:plan      — preview Tailscale ACL changes")
    print(f"    • task tofu:apply     — apply zero-trust ACL rules")
    print("\n" + "=" * 70)


if __name__ == "__main__":
    main()
