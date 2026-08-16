#!/usr/bin/env bash
# LLM Platform Automated Test Suite
set -euo pipefail

PORT=${1:-443}
TOKEN=${2:-"test-key"}
ENDPOINT="https://127.0.0.1:${PORT}"
CURL_OPTS="-s -k --max-time 15"  # -k for self-signed certs during testing

echo "=========================================="
echo "[*] Running LLM Platform Test Suite on ${ENDPOINT}"
echo "=========================================="

# -------------------------------------------------------------
# TEST 1: Negative Authentication Enforcement on API (/v1/models)
# -------------------------------------------------------------
echo "[1/4] Negative Auth Test (Should fail without Bearer token)..."
STATUS=$(curl ${CURL_OPTS} -o /dev/null -w "%{http_code}" "${ENDPOINT}/v1/models" || true)
if [[ "$STATUS" == "401" || "$STATUS" == "403" ]]; then
    echo " --> [PASS] Unauthorized API request blocked correctly (HTTP ${STATUS})"
else
    echo " --> [FAIL] Expected HTTP 401/403, got ${STATUS}"
    exit 1
fi

# -------------------------------------------------------------
# TEST 2: Model Listing with Valid Bearer Token
# -------------------------------------------------------------
echo "[2/4] Testing Model Discovery with Bearer Token..."
MODELS_JSON=$(curl ${CURL_OPTS} -f -H "Authorization: Bearer ${TOKEN}" "${ENDPOINT}/v1/models" 2>/dev/null || echo "FAIL")
if [[ "$MODELS_JSON" != "FAIL" ]]; then
    echo " --> [PASS] Models retrieved successfully:"
    echo "$MODELS_JSON" | jq -r '.data[].id' 2>/dev/null || echo "$MODELS_JSON"
else
    echo " --> [FAIL] Could not retrieve models from /v1/models"
    exit 1
fi

# Verify target model exists before streaming test
TARGET_MODEL="qwen2.5-coder:7b"
if ! echo "$MODELS_JSON" | grep -q "$TARGET_MODEL"; then
    echo " --> [WARN] Target model $TARGET_MODEL not found; using first available model"
    TARGET_MODEL=$(echo "$MODELS_JSON" | jq -r '.data[0].id' 2>/dev/null || echo "qwen2.5-coder:7b")
fi

# -------------------------------------------------------------
# TEST 3: Real-Time SSE Token Streaming
# -------------------------------------------------------------
echo "[3/4] Testing Token Streaming (SSE Chunking) on model: ${TARGET_MODEL}..."
STREAM=$(curl ${CURL_OPTS} -N -X POST "${ENDPOINT}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${TOKEN}" \
    -d "{\"model\": \"${TARGET_MODEL}\", \"messages\": [{\"role\": \"user\", \"content\": \"Ping\"}], \"stream\": true, \"max_tokens\": 5}" 2>/dev/null || true)

if echo "$STREAM" | grep -qE '^data: '; then
    echo " --> [PASS] SSE Streaming active and emitting data chunks."
else
    echo " --> [FAIL] Streaming test failed or timed out."
    echo "Raw output (first 200 chars): ${STREAM:0:200}"
    exit 1
fi

# -------------------------------------------------------------
# TEST 4: Frontend WebUI Ingress Health (/ endpoint)
# -------------------------------------------------------------
echo "[4/4] Testing Open WebUI Ingress Health (Root path /)..."
UI_STATUS=$(curl ${CURL_OPTS} -o /dev/null -w "%{http_code}" "${ENDPOINT}/" || true)
if [[ "$UI_STATUS" == "200" || "$UI_STATUS" == "302" || "$UI_STATUS" == "307" ]]; then
    echo " --> [PASS] Open WebUI frontend reachable on port ${PORT} (HTTP ${UI_STATUS})"
else
    echo " --> [FAIL] Open WebUI unreachable, returned HTTP ${UI_STATUS}"
    exit 1
fi

echo "=========================================="
echo "✔ All 4 Integration Tests Passed Successfully!"
echo "=========================================="
