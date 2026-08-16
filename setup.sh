#!/usr/bin/env bash
# 1-Click Host Bootstrapper & Setup Launcher
set -e

echo "============================================================"
echo " Starting 1-Click Local LLM Platform Bootstrapper..."
echo "============================================================"

# 1. Ensure ~/.local/bin exists and is in PATH
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"

# 2. Check if Docker is installed and running
if ! command -v docker >/dev/null 2>&1; then
    echo "[-] Error: Docker is not installed. Please install Docker Engine / Docker Desktop first."
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "[*] Starting Docker daemon..."
    sudo service docker start 2>/dev/null || true
    sleep 2
fi

# 3. Check if Taskfile is installed; if not, install it locally
if ! command -v task >/dev/null 2>&1; then
    echo "[*] Installing Taskfile CLI..."
    sh -c "$(curl --location https://taskfile.dev/install.sh)" -- -d -b "$HOME/.local/bin"
fi

# 4. Launch the hardware-profiling wizard
python3 "$(dirname "$0")/scripts/wizard.py"
