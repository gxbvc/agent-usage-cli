# agent-usage-cli

Read subscription usage for locally logged-in Claude Code, Codex, and Grok Build CLIs as JSON.

## Commands

```bash
agent-usage-cli                              # Query all providers concurrently
agent-usage-cli --provider claude            # Query one provider
agent-usage-cli --provider claude,codex      # Query a comma-separated selection
agent-usage-cli --provider codex --provider grok  # Repeat provider selection
agent-usage-cli --include-history            # Include Codex daily token buckets
agent-usage-cli --pretty                     # Indent JSON
agent-usage-cli --strict                     # Exit 1 if any selected provider fails
```

## Output

```json
{"ok":true,"data":{"complete":true,"providers":{},"errors":[]}}
```

Partial failures set `complete` to false and add a stable, secret-safe entry to `errors`. Successful providers remain in `providers`. Default mode exits 0 for partial failures. `--strict` exits 1.

No `.env` or separate credentials are required. The tool uses existing local CLI logins and never invokes a model.
