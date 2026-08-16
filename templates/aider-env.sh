#!/usr/bin/env bash
# Aider CLI Agent Environment Configuration
export OPENAI_API_BASE="http://100.107.215.58:443/v1"
export OPENAI_API_KEY="sk-trainee-test-token-12345"

echo "[+] Targeted LLM Gateway at ${OPENAI_API_BASE}"
echo "[+] Starting Aider with Local Qwen 2.5 Coder..."

# Launch Aider agent targeting local GPU
aider --model openai/qwen2.5-coder:7b
