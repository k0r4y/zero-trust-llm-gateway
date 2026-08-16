#!/usr/bin/env bash
# LLM Platform Automated Test Suite
set -e

PORT=${1:-443}
TOKEN=${2:-"test-key"}
ENDPOINT="http://127.0.0.1:${PORT}"

echo "=========================================="
echo "[*] Running LLM Platform Test Suite on ${ENDPOINT}"
echo "=========================================="

# -------------------------------------------------------------
# TEST 1: Negative Authentication Enforcement on API (/v1/models)
# -------------------------------------------------------------
echo "[1/4] Negative Auth Test (Should fail without Bearer token)..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${ENDPOINT}/v1/models" || true)
if [[ "$STATUS" == "401" || "$STATUS" == "403" ]]; then
    echo "  --> [PASS] Unauthorized API request blocked correctly (HTTP ${STATUS})"
else
    echo "  --> [FAIL] Expected HTTP 401/403, got ${STATUS}"
    exit 1
fi

# -------------------------------------------------------------
# TEST 2: Model Listing with Valid Bearer Token
# -------------------------------------------------------------
echo "[2/4] Testing Model Discovery with Bearer Token..."
MODELS=$(curl -s -f -H "Authorization: Bearer ${TOKEN}" "${ENDPOINT}/v1/models" 2>/dev/null || echo "FAIL")
if [[ "$MODELS" != "FAIL" ]]; then
    echo "  --> [PASS] Models retrieved successfully:"
    echo "$MODELS" | jq -r '.data[].id' 2>/dev/null || echo "$MODELS"
else
    echo "  --> [FAIL] Could not retrieve models from /v1/models"
    exit 1
fi

# -------------------------------------------------------------
# TEST 3: Real-Time SSE Token Streaming
# -------------------------------------------------------------
echo "[3/4] Testing Token Streaming (SSE Chunking)..."
STREAM=$(curl -s -N -X POST "${ENDPOINT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${TOKEN}" \
  -d '{"model": "qwen2.5-coder:7b", "messages": [{"role": "user", "content": "Ping"}], "stream": true, "max_tokens": 5}' 2>/dev/null || true)

if echo "$STREAM" | grep -q "data:"; then
    echo "  --> [PASS] SSE Streaming active and emitting data chunks."
else
    echo "  --> [FAIL] Streaming test failed or timed out."
    exit 1
fi

# -------------------------------------------------------------
# TEST 4: Frontend WebUI Ingress Health (/ endpoint)
# -------------------------------------------------------------
echo "[4/4] Testing Open WebUI Ingress Health (Root path /)..."
UI_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${ENDPOINT}/" || true)
if [[ "$UI_STATUS" == "200" || "$UI_STATUS" == "302" || "$UI_STATUS" == "307" ]]; then
    echo "  --> [PASS] Open WebUI frontend reachable on port ${PORT} (HTTP ${UI_STATUS})"
else
    echo "  --> [FAIL] Open WebUI unreachable, returned HTTP ${UI_STATUS}"
    exit 1
fi

echo "=========================================="
echo "✔ All 4 Integration Tests Passed Successfully!"
echo "=========================================="
