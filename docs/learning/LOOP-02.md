# Loop 2: Hardened Ingress & Real-Time Streaming Gateway

### Architectural Decisions & SecOps Takeaways
1. **L7 Ingress Hardening:** Nginx serves as the single exposed edge ingress on ports `443` and `11434`. Port `4000` (LiteLLM) was stripped of host port-binding.
2. **SSE Streaming Enablement:** `proxy_buffering off;` and `chunked_transfer_encoding on;` allow immediate token streaming over HTTP/1.1 without intermediate proxy buffering delays.
3. **GPU DoS Protection:** `limit_req_zone` enforces a 15 req/s rate limit with a 30-request burst buffer, dropping runaway client loops with `HTTP 429`.
4. **Deep Reasoning Resilience:** `proxy_read_timeout 600s;` prevents connection severance during lengthy multi-step reasoning generation chains.
