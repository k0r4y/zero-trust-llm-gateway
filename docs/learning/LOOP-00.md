# Loop 0: Baseline Freeze & Repository Scaffolding

### Architectural Decisions & SecOps Takeaways
1. **Separation of State and Code:** Docker volumes (`ollama_data`) persist independently of container definitions. Recreating containers does not trigger 10GB+ model re-downloads.
2. **Pre-Flight Git Security:** `.gitignore` is established *before* generating secrets or state files to avoid accidental credential leaks into Git history.
