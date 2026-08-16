#!/usr/bin/env bash
# =============================================================================
# 1-Click Host Bootstrapper & Setup Launcher
# =============================================================================
# Security note: This script runs with set -e to fail fast on any error.
# We never curl | sh untrusted binaries without verification.
# =============================================================================
set -euo pipefail

echo "============================================================"
echo "  ZERO-TRUST LOCAL LLM PLATFORM — BOOTSTRAPPER"
echo "============================================================"

# -----------------------------------------------------------------------------
# 1. Ensure ~/.local/bin exists and is in PATH
# -----------------------------------------------------------------------------
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"

# -----------------------------------------------------------------------------
# 2. Docker Engine check
# -----------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    echo "[-] Docker is not installed."
    echo "    Install:  curl -fsSL https://get.docker.com | sudo sh"
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "[*] Docker daemon not running. Attempting to start..."
    sudo service docker start 2>/dev/null || sudo systemctl start docker 2>/dev/null || true
    sleep 3
    if ! docker info >/dev/null 2>&1; then
        echo "[-] Failed to start Docker daemon. Check: sudo systemctl status docker"
        exit 1
    fi
fi
echo "[✔] Docker is running"

# -----------------------------------------------------------------------------
# 3. Taskfile CLI check / install
# -----------------------------------------------------------------------------
if ! command -v task >/dev/null 2>&1; then
    echo "[*] Taskfile CLI not found. Installing to ~/.local/bin ..."
    # Pin to a specific release for supply-chain security
    TASK_VERSION="v3.38.0"
    TASK_URL="https://github.com/go-task/task/releases/download/${TASK_VERSION}/task_linux_amd64.tar.gz"
    TMP_DIR=$(mktemp -d)
    curl -fsSL "$TASK_URL" | tar -xz -C "$TMP_DIR" task
    mv "$TMP_DIR/task" "$HOME/.local/bin/task"
    rm -rf "$TMP_DIR"
    echo "[✔] Taskfile ${TASK_VERSION} installed"
else
    echo "[✔] Taskfile detected"
fi

# -----------------------------------------------------------------------------
# 4. Python 3 check
# -----------------------------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
    echo "[-] Python 3 is required but not installed."
    exit 1
fi
echo "[✔] Python 3 detected"

# -----------------------------------------------------------------------------
# 5. Launch the interactive wizard
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo ""
echo "[*] Launching interactive setup wizard..."
python3 "${SCRIPT_DIR}/scripts/wizard.py"
