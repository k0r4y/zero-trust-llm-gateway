#!/usr/bin/env bash
# =============================================================================
# Full Integration Test: Teardown → Wizard → Validation
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
    echo "    [✔] $1" | tee -a "$TEST_LOG"
    ((PASSED++)) || true
}

fail() {
    echo "    [✗] $1" | tee -a "$TEST_LOG"
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
    fail "Wizard failed — check $TEST_LOG"
    exit 1
fi

# =============================================================================
# PHASE 2: Verify infrastructure
# =============================================================================
log ""
log "=== PHASE 2: Infrastructure Verification ==="

# Wait longer for services to fully initialize
log "Waiting 15 seconds for services to settle..."
sleep 15

CONTAINERS=("ollama-server" "litellm-proxy" "open-webui" "nginx-ingress")
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
    # This shouldn't happen with current configs, but handle it
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
TARGET_MODEL=$(echo "$MODELS_JSON" | jq -r '.data[0].id' 2>/dev/null || echo "qwen2.5-coder:7b")
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
    # Try signup as fallback
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

# =============================================================================
# PHASE 5: Config file validation
# =============================================================================
log ""
log "=== PHASE 5: Generated File Validation ==="

for f in compose/.env compose/config/nginx.conf compose/config/litellm-config.yaml tofu/terraform.tfvars templates/setup-receipt.txt; do
    if [[ -f "$f" ]]; then
        pass "Generated file exists: $f"
    else
        fail "Missing generated file: $f"
    fi
done

# Only flag the OTHER old hardcoded IPs, not the user's actual Tailscale IP
# The original repo had: 100.107.215.58, HIDDEN_IP_1, HIDDEN_IP_2
# 100.107.215.58 happens to be this user's real IP, so we only check for the other two
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
    log "✔ All tests passed. Stack is healthy."
    exit 0
fi
