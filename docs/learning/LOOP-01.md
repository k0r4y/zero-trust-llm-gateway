# Loop 1: Declarative Compose & LiteLLM Gateway

### Architectural Decisions & SecOps Takeaways
1. **Network Boundary Isolation:** Ollama has zero exposed host ports. It accepts TCP traffic strictly originating from the internal Docker bridge network (`llm-net`).
2. **API Normalization:** LiteLLM validates standard RFC 6750 `Authorization: Bearer` tokens and translates OpenAI `/v1` endpoints to Ollama's internal format.
3. **Volume Continuity:** The `external: true` directive bound directly to the pre-existing named volume `ollama_data`, preserving model weights without a 15GB redownload.
4. **VRAM Optimization:** `OLLAMA_MAX_LOADED_MODELS=2` enables concurrent memory residency for coding and embedding models without eviction thrashing.
