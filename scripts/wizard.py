#!/usr/bin/env python3
"""
Hardware Profiling & Onboarding Wizard
Detects GPU VRAM, recommends optimal model tiers, and automates stack configuration.
"""
import os
import sys
import shutil
import subprocess

def print_banner():
    print("=" * 64)
    print("   ZERO-TRUST LOCAL LLM PLATFORM - ONBOARDING WIZARD")
    print("=" * 64)

def detect_gpu():
    """Detects NVIDIA GPU model and total VRAM in Gigabytes using nvidia-smi."""
    print("\n[*] Inspecting host hardware...")
    nvidia_smi = shutil.which("nvidia-smi")
    
    if not nvidia_smi:
        print("  --> [!] No NVIDIA GPU detected. Falling back to CPU mode.")
        return 0, "CPU Only"
    
    try:
        cmd = ["nvidia-smi", "--query-gpu=name,memory.total", "--format=csv,noheader,nounits"]
        output = subprocess.check_output(cmd, encoding="utf-8").strip()
        gpu_name, vram_mb = output.split(",")
        vram_gb = round(float(vram_mb.strip()) / 1024, 1)
        print(f"  --> [✔] Detected GPU: {gpu_name.strip()} ({vram_gb} GB VRAM)")
        return vram_gb, gpu_name.strip()
    except Exception as e:
        print(f"  --> [!] Failed to query nvidia-smi: {e}. Defaulting to CPU mode.")
        return 0, "CPU Fallback"

def recommend_tier(vram_gb):
    """Selects the optimal model tier based on available VRAM."""
    if vram_gb >= 15.0:
        return "Tier 3 (High Performance)", ["deepseek-r1:14b", "qwen2.5-coder:7b", "nomic-embed-text"]
    elif vram_gb >= 8.0:
        return "Tier 2 (Balanced Reasoning & Code)", ["deepseek-r1:7b", "qwen2.5-coder:7b", "nomic-embed-text"]
    else:
        return "Tier 1 (Lightweight / CPU Friendly)", ["qwen2.5:3b", "qwen2.5-coder:1.5b", "nomic-embed-text"]

def get_tailscale_ip():
    """Fetches local Tailscale IP if connected."""
    tailscale_bin = shutil.which("tailscale")
    if tailscale_bin:
        try:
            return subprocess.check_output(["tailscale", "ip", "-4"], encoding="utf-8").strip()
        except Exception:
            pass
    return "127.0.0.1"

def main():
    print_banner()
    vram_gb, gpu_name = detect_gpu()
    tier_name, models = recommend_tier(vram_gb)
    
    print(f"\n[+] Recommended Configuration for your system:")
    print(f"    Tier:   {tier_name}")
    print(f"    Models: {', '.join(models)}")
    
    tailscale_ip = get_tailscale_ip()
    print(f"    Network: Tailscale IP detected as {tailscale_ip}")
    
    confirm = input("\n[?] Apply this configuration and launch stack? [Y/n]: ").strip().lower()
    if confirm in ["n", "no"]:
        print("[*] Setup aborted by user.")
        sys.exit(0)
        
    print("\n[*] Generating configuration files...")
    
    # 1. Update litellm-config.yaml with recommended models
    config_path = os.path.expanduser("~/llm-platform-iac/compose/config/litellm-config.yaml")
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
    print("  --> [✔] Generated compose/config/litellm-config.yaml")

    # 2. Start stack via task up
    print("\n[*] Starting LLM Platform containers...")
    subprocess.run(["task", "up"], check=True)
    
    # 3. Pull recommended models in background
    print("\n[*] Pulling recommended models into Ollama (this may take a few minutes)...")
    for m in models:
        print(f"  --> Pulling {m}...")
        subprocess.run(["docker", "exec", "-i", "ollama-server", "ollama", "pull", m], check=False)
        
    print("\n" + "=" * 64)
    print("✔ Setup Complete! Platform is ready for use.")
    print("=" * 64)
    print(f"  Web Chat UI:    http://{tailscale_ip}:443/")
    print(f"  OpenAI API:     http://{tailscale_ip}:443/v1")
    print(f"  Client Guides:  ~/llm-platform-iac/templates/")
    print("=" * 64)

if __name__ == "__main__":
    main()
