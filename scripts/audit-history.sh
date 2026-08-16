#!/usr/bin/env bash
set -euo pipefail

cd ~/llm-platform-iac

echo "============================================================"
echo "  GIT HISTORY SECRET AUDIT"
echo "============================================================"

if ! command -v git-filter-repo >/dev/null 2>&1; then
    echo "[*] Installing git-filter-repo..."
    pip3 install git-filter-repo
fi

FOUND_ISSUES=0

# Pattern 1: LiteLLM master keys
echo ""
echo "--- Pattern 1: LiteLLM master keys ---"
if git log --all -p -S "LITELLM_MASTER_KEY=sk-" -- "*.env" "*.yaml" "*.yml" "*.py" "*.sh" 2>/dev/null | head -20 | grep -q "sk-"; then
    echo "    [✗] FOUND: LiteLLM master keys in history"
    git log --all --oneline -S "LITELLM_MASTER_KEY=sk-" -- "*.env" "*.yaml" "*.yml" | head -5
    FOUND_ISSUES=1
else
    echo "    [✔] No LiteLLM master keys found in history"
fi

# Pattern 2: Tailscale OAuth secrets
echo ""
echo "--- Pattern 2: Tailscale OAuth secrets ---"
if git log --all -p -S "TAILSCALE_OAUTH_SECRET=tskey-client-" -- "*.env" "*.yaml" "*.yml" 2>/dev/null | head -20 | grep -q "tskey-client-"; then
    echo "    [✗] FOUND: Tailscale OAuth secrets in history"
    git log --all --oneline -S "TAILSCALE_OAUTH_SECRET=tskey-client-" -- "*.env" "*.yaml" "*.yml" | head -5
    FOUND_ISSUES=1
else
    echo "    [✔] No Tailscale OAuth secrets found in history"
fi

# Pattern 3: Hardcoded Tailscale IPs
echo ""
echo "--- Pattern 3: Hardcoded Tailscale IPs ---"
BAD_IPS=("100.77.206.37" "100.99.132.22")
for ip in "${BAD_IPS[@]}"; do
    if git log --all -p -S "$ip" 2>/dev/null | grep -q "$ip"; then
        echo "    [✗] FOUND: Hardcoded IP $ip in history"
        git log --all --oneline -S "$ip" | head -3
        FOUND_ISSUES=1
    fi
done

# Pattern 4: secrets.enc.yaml
echo ""
echo "--- Pattern 4: secrets.enc.yaml file ---"
if git log --all --oneline -- secrets.enc.yaml 2>/dev/null | grep -q .; then
    echo "    [✗] FOUND: secrets.enc.yaml was committed to history"
    git log --all --oneline -- secrets.enc.yaml | head -5
    FOUND_ISSUES=1
else
    echo "    [✔] secrets.enc.yaml not found in history"
fi

# Pattern 5: compose/.env with real values
echo ""
echo "--- Pattern 5: compose/.env files ---"
if git log --all -p -- compose/.env 2>/dev/null | grep -E "^\+.*=sk-|^\+.*=tskey-client-" | head -5 | grep -q .; then
    echo "    [✗] FOUND: compose/.env with real secrets in history"
    FOUND_ISSUES=1
else
    echo "    [✔] No compose/.env with real secrets in history"
fi

# Pattern 6: terraform.tfvars with hardcoded IPs
echo ""
echo "--- Pattern 6: terraform.tfvars ---"
if git log --all -p -- tofu/terraform.tfvars 2>/dev/null | grep -E "100\.[0-9]+\.[0-9]+\.[0-9]+" | head -5 | grep -q .; then
    echo "    [✗] FOUND: terraform.tfvars with hardcoded IPs in history"
    FOUND_ISSUES=1
else
    echo "    [✔] No terraform.tfvars with hardcoded IPs in history"
fi

echo ""
echo "============================================================"
if [[ $FOUND_ISSUES -eq 1 ]]; then
    echo "  [✗] SENSITIVE DATA FOUND IN GIT HISTORY"
    echo "============================================================"
    echo ""
    echo "To purge everything, run:"
    echo ""
    echo "  git filter-repo \\"
    echo "    --path secrets.enc.yaml --invert-paths \\"
    echo "    --path compose/.env --invert-paths \\"
    echo "    --path tofu/terraform.tfvars --invert-paths \\"
    echo "    --replace-text <(echo '100.77.206.37==>HIDDEN_IP_1'; echo '100.99.132.22==>HIDDEN_IP_2') \\"
    echo "    --force"
    echo ""
    echo "Then: git push origin --force --all"
    echo ""
    echo "WARNING: This rewrites ALL commit hashes. Anyone with a clone must re-clone."
    echo ""
    read -p "Run git-filter-repo now? [y/N] " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        REPL_FILE=$(mktemp)
        echo "100.77.206.37==>HIDDEN_IP_1" > "$REPL_FILE"
        echo "100.99.132.22==>HIDDEN_IP_2" >> "$REPL_FILE"
        git filter-repo \
            --path secrets.enc.yaml --invert-paths \
            --path compose/.env --invert-paths \
            --path tofu/terraform.tfvars --invert-paths \
            --replace-text "$REPL_FILE" \
            --force
        rm -f "$REPL_FILE"
        echo ""
        echo "[✔] History rewritten. Now run: git push origin --force --all"
    fi
else
    echo "  [✔] NO SENSITIVE DATA FOUND IN GIT HISTORY"
    echo "============================================================"
fi
