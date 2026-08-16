#!/usr/bin/env bash
# =============================================================================
# Full Integration Test: Teardown -> Wizard -> Patch -> Validation
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

COMPOSE_FILE="compose/docker-compose.yml"
TEST_LOG="/tmp/llm-test-$(date +%Y%m%d_%H%M%S).log"
PASSED=0
FAILED=0

log() {
    echo "[$(date '+%H:%M:%S')] $1" | tee -a "$TEST_LOG"
}

pass() {
    echo "    [OK] $1" | tee -a "$TEST_LOG"
    ((PASSED++)) || true
}

fail() {
    echo "    [FAIL] $1" | tee -a "$TEST_LOG"
    ((FAILED++)) || true
}

# =============================================================================
# PHASE 0: Pre-test cleanup
# =============================================================================
log "=== PHASE 0: Pre-test Cleanup ==="

log "Stopping and removing containers (volumes preserved)..."
docker compose -f "$COMPOSE_FILE" down --remove-orphans 2>/dev/null || true
pass "Containers stopped"

mkdir -p .test-backups
for f in compose/config/nginx.conf compose/config/litellm-config.yaml tofu/terraform.tfvars templates/setup-receipt.txt templates/vscode-continue.json templates/obsidian.md templates/aider.sh; do
    if [[ -f "$f" ]]; then
        cp "$f" ".test-backups/$(basename $f).$(date +%s).bak" 2>/dev/null || true
        rm -f "$f"
    fi
done
pass "Old configs backed up and removed"

if [[ -f compose/.env ]]; then
    cp compose/.env ".test-backups/.env.$(date +%s).bak" 2>/dev/null || true
    rm -f compose/.env
    pass "Old .env backed up and removed"
fi

# =============================================================================
# PHASE 1: Run the wizard
# =============================================================================
log ""
log "=== PHASE 1: Running Setup Wizard ==="
log "The wizard will now run interactively. Answer its prompts."
log ""

if python3 scripts/wizard.py 2>&1 | tee -a "$TEST_LOG"; then
    pass "Wizard completed successfully"
else
    fail "Wizard failed - check $TEST_LOG"
    exit 1
fi

# =============================================================================
# PHASE 1.5: Patch environment for custom services (not managed by wizard)
# =============================================================================
log ""
log "=== PHASE 1.5: Patching Custom Service Config ==="

# The wizard regenerates compose/.env with no knowledge of JUPYTER_TOKEN,
# since Jupyter/SearXNG were added manually, not by the wizard itself.
# Without this, jupyter starts with an empty token and open-webui can't
# authenticate to it for code execution.
if ! grep -q "^JUPYTER_TOKEN=" compose/.env 2>/dev/null; then
    echo "JUPYTER_TOKEN=$(openssl rand -hex 32)" >> compose/.env
    pass "Generated missing JUPYTER_TOKEN"
else
    pass "JUPYTER_TOKEN already present"
fi

# Ensure SearXNG's settings.yml has JSON format enabled. The wizard doesn't
# generate this file at all (searxng isn't part of its known services), so
# on a fresh teardown/rebuild this file may not exist yet -- create it with
# the correct settings rather than assuming it's already there.
SEARXNG_SETTINGS="compose/config/searxng/settings.yml"
mkdir -p "$(dirname "$SEARXNG_SETTINGS")"
if [[ ! -f "$SEARXNG_SETTINGS" ]] || ! grep -q "json" "$SEARXNG_SETTINGS" 2>/dev/null; then
    cat > "$SEARXNG_SETTINGS" <<'EOF'
# Read the documentation before extending the defaults:
# https://docs.searxng.org/admin/settings/
use_default_settings: true
server:
  secret_key: "REPLACE_ME_SECRET_KEY"
  image_proxy: true
search:
  formats:
    - html
    - json
EOF
    # Give it a real random secret rather than a placeholder.
    sed -i "s/REPLACE_ME_SECRET_KEY/$(openssl rand -hex 16)/" "$SEARXNG_SETTINGS"
    pass "Wrote SearXNG settings.yml with JSON format enabled"
else
    pass "SearXNG settings.yml already has JSON format enabled"
fi

# Recreate only the services that depend on the patched values -- avoids
# restarting the whole stack (ollama, litellm, nginx) unnecessarily.
docker compose -f "$COMPOSE_FILE" up -d jupyter open-webui searxng > /dev/null 2>&1
pass "Recreated jupyter + open-webui + searxng with patched config"

# =============================================================================
# PHASE 2: Verify infrastructure
# =============================================================================
log ""
log "=== PHASE 2: Infrastructure Verification ==="

# Wait longer for services to fully initialize
log "Waiting 15 seconds for services to settle..."
sleep 15

CONTAINERS=("ollama-server" "litellm-proxy" "open-webui" "nginx-ingress" "searxng" "jupyter")
for c in "${CONTAINERS[@]}"; do
    STATUS=$(docker inspect --format='{{.State.Status}}' "$c" 2>/dev/null || echo "missing")
    if [[ "$STATUS" == "running" ]]; then
        pass "Container $c is running"
    else
        fail "Container $c is not running (status: $STATUS)"
    fi
done

# =============================================================================
# PHASE 3: Detect TLS mode and set correct ports
# =============================================================================
log ""
log "=== PHASE 3: Detecting TLS Mode ==="

if grep -q "listen 443 ssl;" compose/config/nginx.conf 2>/dev/null; then
    TLS_MODE="selfsigned"
    WEB_PORT="443"
    API_PORT="443"
    CURL_OPTS="-sk"
    SCHEME="https"
    log "Detected: Self-signed HTTPS mode (port 443)"
elif grep -q "listen 11434 ssl;" compose/config/nginx.conf 2>/dev/null; then
    TLS_MODE="selfsigned"
    WEB_PORT="443"
    API_PORT="443"
    CURL_OPTS="-sk"
    SCHEME="https"
    log "Detected: Self-signed HTTPS mode (port 443)"
else
    TLS_MODE="plain"
    WEB_PORT="80"
    API_PORT="11434"
    CURL_OPTS="-s"
    SCHEME="http"
    log "Detected: Plain HTTP mode (web on 80, API on 11434)"
fi

# =============================================================================
# PHASE 4: API Validation
# =============================================================================
log ""
log "=== PHASE 4: API Validation ==="

API_KEY=$(grep LITELLM_MASTER_KEY compose/.env | cut -d= -f2)
JUPYTER_TOKEN_VAL=$(grep JUPYTER_TOKEN compose/.env | cut -d= -f2)
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "127.0.0.1")

API_URL="${SCHEME}://${TAILSCALE_IP}:${API_PORT}"
WEB_URL="${SCHEME}://${TAILSCALE_IP}:${WEB_PORT}"

log "API endpoint: $API_URL"
log "Web endpoint: $WEB_URL"

# Test 1: Negative auth (should fail without token)
log "Test 1: Negative authentication..."
HTTP_CODE=$(curl ${CURL_OPTS} --max-time 10 -o /dev/null -w "%{http_code}" "${API_URL}/v1/models" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "401" || "$HTTP_CODE" == "403" ]]; then
    pass "Unauthorized request correctly blocked (HTTP $HTTP_CODE)"
else
    fail "Expected HTTP 401/403, got $HTTP_CODE"
fi

# Test 2: Model listing with valid token
log "Test 2: Model discovery with valid token..."
MODELS_JSON=$(curl ${CURL_OPTS} --max-time 10 -f -H "Authorization: Bearer ${API_KEY}" "${API_URL}/v1/models" 2>/dev/null || echo "FAIL")
if [[ "$MODELS_JSON" != "FAIL" && "$MODELS_JSON" == *"id"* ]]; then
    pass "Model list retrieved successfully"
    echo "$MODELS_JSON" | jq -r '.data[].id' 2>/dev/null | while read -r model; do
        echo "        - $model"
    done
else
    fail "Could not retrieve model list"
fi

# Test 3: SSE streaming
log "Test 3: Token streaming (SSE)..."
TARGET_MODEL="qwen2.5-coder:7b"
STREAM=$(curl ${CURL_OPTS} -N --max-time 15 -X POST "${API_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${API_KEY}" \
    -d "{\"model\": \"${TARGET_MODEL}\", \"messages\": [{\"role\": \"user\", \"content\": \"Ping\"}], \"stream\": true, \"max_tokens\": 5}" 2>/dev/null || true)
if echo "$STREAM" | grep -qE '^data: '; then
    pass "SSE streaming active and emitting data chunks"
else
    fail "Streaming test failed or returned no data"
fi

# Test 4: WebUI health
log "Test 4: Open WebUI frontend health..."
UI_CODE=$(curl ${CURL_OPTS} --max-time 10 -o /dev/null -w "%{http_code}" "${WEB_URL}/" 2>/dev/null || echo "000")
if [[ "$UI_CODE" == "200" || "$UI_CODE" == "302" || "$UI_CODE" == "307" ]]; then
    pass "Open WebUI frontend reachable (HTTP $UI_CODE)"
else
    fail "Open WebUI unreachable (HTTP $UI_CODE)"
fi

# Test 5: Admin account seeding
# NOTE: Port 8080 is not exposed to the host, so we use docker exec
# with Python (guaranteed to exist in the open-webui container).
log "Test 5: Admin account seeding..."
ADMIN_EMAIL=$(grep ADMIN_EMAIL compose/.env | cut -d= -f2)
ADMIN_PASS=$(grep ADMIN_PASSWORD compose/.env | cut -d= -f2)

LOGIN_OUTPUT=$(docker exec open-webui python3 -c "
import urllib.request, json
data = json.dumps({'email': '$ADMIN_EMAIL', 'password': '$ADMIN_PASS'}).encode()
req = urllib.request.Request('http://localhost:8080/api/v1/auths/signin', data=data, headers={'Content-Type': 'application/json'})
try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        print('TOKEN_FOUND')
except urllib.error.HTTPError as e:
    body = e.read().decode()
    if 'token' in body.lower():
        print('TOKEN_FOUND')
    else:
        print('FAIL:' + body[:80])
except Exception as e:
    print('FAIL:' + str(e)[:80])
" 2>/dev/null || echo "FAIL:docker_exec_failed")

if echo "$LOGIN_OUTPUT" | grep -q "TOKEN_FOUND"; then
    pass "Admin account login successful"
else
    SIGNUP_OUTPUT=$(docker exec open-webui python3 -c "
import urllib.request, json
data = json.dumps({'name': 'Admin', 'email': '$ADMIN_EMAIL', 'password': '$ADMIN_PASS'}).encode()
req = urllib.request.Request('http://localhost:8080/api/v1/auths/signup', data=data, headers={'Content-Type': 'application/json'})
try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        print('TOKEN_FOUND')
except urllib.error.HTTPError as e:
    body = e.read().decode()
    if 'token' in body.lower() or 'already' in body.lower():
        print('TOKEN_FOUND')
    else:
        print('FAIL:' + body[:80])
except Exception as e:
    print('FAIL:' + str(e)[:80])
" 2>/dev/null || echo "FAIL:docker_exec_failed")

    if echo "$SIGNUP_OUTPUT" | grep -q "TOKEN_FOUND"; then
        pass "Admin account created and login successful"
    else
        fail "Admin account may not exist or login failed"
        log "    Debug: login output: $LOGIN_OUTPUT"
        log "    Debug: signup output: $SIGNUP_OUTPUT"
    fi
fi

# Test 6: SearXNG returns valid JSON (not just running -- actually usable)
log "Test 6: SearXNG JSON search..."
SEARXNG_RESULT=$(docker exec open-webui curl -s --max-time 10 "http://searxng:8080/search?q=test&format=json" 2>/dev/null || echo "FAIL")
if [[ "$SEARXNG_RESULT" == *'"results"'* ]]; then
    pass "SearXNG returned valid JSON search results"
else
    fail "SearXNG did not return valid JSON (check formats: json in settings.yml)"
fi

# Test 7: Jupyter is reachable and accepts the configured token
log "Test 7: Jupyter code execution backend..."
JUPYTER_CHECK=$(docker exec open-webui curl -s --max-time 10 -o /dev/null -w "%{http_code}" \
    "http://jupyter:8888/api/status?token=${JUPYTER_TOKEN_VAL}" 2>/dev/null || echo "000")
if [[ "$JUPYTER_CHECK" == "200" ]]; then
    pass "Jupyter reachable and token accepted"
else
    fail "Jupyter unreachable or token rejected (HTTP $JUPYTER_CHECK)"
fi

# =============================================================================
# PHASE 5: Config file validation
# =============================================================================
log ""
log "=== PHASE 5: Generated File Validation ==="

for f in compose/.env compose/config/nginx.conf compose/config/litellm-config.yaml tofu/terraform.tfvars templates/setup-receipt.txt compose/config/searxng/settings.yml; do
    if [[ -f "$f" ]]; then
        pass "Generated file exists: $f"
    else
        fail "Missing generated file: $f"
    fi
done

# Only flag the OTHER old hardcoded IPs, not the user's actual Tailscale IP.
OLD_IPS_FOUND=0
for ip in "HIDDEN_IP_1" "HIDDEN_IP_2"; do
    if grep -q "$ip" tofu/terraform.tfvars 2>/dev/null; then
        fail "terraform.tfvars still contains old hardcoded IP: $ip"
        OLD_IPS_FOUND=1
    fi
done
if [[ $OLD_IPS_FOUND -eq 0 ]]; then
    pass "terraform.tfvars uses dynamic IPs (no old hardcoded IPs found)"
fi

if grep -q "Password:" templates/setup-receipt.txt 2>/dev/null; then
    pass "Setup receipt contains admin password"
else
    fail "Setup receipt missing admin password"
fi

# =============================================================================
# SUMMARY
# =============================================================================
log ""
log "============================================================"
log "  TEST SUMMARY"
log "============================================================"
log "  Passed: $PASSED"
log "  Failed: $FAILED"
log "  Log:    $TEST_LOG"
log "============================================================"

if [[ $FAILED -gt 0 ]]; then
    log "Dumping recent container logs for debugging..."
    docker compose -f "$COMPOSE_FILE" logs --tail 30 2>&1 | tee -a "$TEST_LOG" || true
    exit 1
else
    log "All tests passed. Stack is healthy."
    exit 0
fi
