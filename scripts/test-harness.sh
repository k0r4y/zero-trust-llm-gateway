#!/usr/bin/env bash
set -e

PORT=${1:-443}
TOKEN=${2:-"test-key"}
ENDPOINT="http://127.0.0.1:${PORT}"

echo "=========================================="
echo "[*] Running LLM Gateway Test Suite on ${ENDPOINT}"
echo "=========================================="

echo "[1/4] Negative Auth Test (Should fail without Bearer token)..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${ENDPOINT}/v1/models" || true)
if [[ "$STATUS" == "401" || "$STATUS" == "403" ]]; then
    echo "  --> [PASS] Unauthorized request blocked correctly (HTTP ${STATUS})"
else
    echo "  --> [WARN] Expected HTTP 401/403, got ${STATUS} (Gateway may be down or unauthenticated)"
fi

echo "[2/4] Testing Model List with Bearer Token..."
MODELS=$(curl -s -f -H "Authorization: Bearer ${TOKEN}" "${ENDPOINT}/v1/models" 2>/dev/null || echo "FAIL")
if [[ "$MODELS" != "FAIL" ]]; then
    echo "  --> [PASS] Models retrieved successfully:"
    echo "$MODELS" | jq -r '.data[].id' 2>/dev/null || echo "$MODELS"
else
    echo "  --> [FAIL] Could not retrieve models."
fi

echo "[3/4] Testing Token Streaming (SSE)..."
STREAM=$(curl -s -N -X POST "${ENDPOINT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${TOKEN}" \
  -d '{"model": "qwen2.5-coder:7b", "messages": [{"role": "user", "content": "Ping"}], "stream": true, "max_tokens": 5}' 2>/dev/null || true)

if echo "$STREAM" | grep -q "data:"; then
    echo "  --> [PASS] SSE Streaming active and working."
else
    echo "  --> [FAIL] Streaming test failed."
fi
echo "=========================================="
