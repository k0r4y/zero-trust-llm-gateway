# Loop 3: Open WebUI Frontend Integration, SOPS Secret Encryption & Taskfile

### Architectural Decisions & SecOps Takeaways
1. **Unified L7 Ingress:** Nginx routes both the human interface (`/` -> Open WebUI:8080) and machine API (`/v1/` -> LiteLLM:4000) over a single port (`443`).
2. **WebSocket Proxying:** Added `Upgrade` and `Connection: upgrade` headers to Nginx to support Open WebUI live chat streaming and status updates.
3. **GitOps Secret Encryption:** Secrets are committed exclusively as SOPS-encrypted `secrets.enc.yaml` files using asymmetric `age` keys. Raw `.env` files are generated just-in-time and ignored by Git.
4. **Declarative Task Automation:** Taskfile (`go-task`) abstracts orchestration lifecycle (`task up`, `task down`, `task test:e2e`) with automated dependency chains.
