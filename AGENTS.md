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
{"ok":true,"data":{"schemaVersion":1,"observedAt":"2026-08-09T04:00:00.000Z","complete":true,"providers":{},"errors":[]}}
```

Partial failures set `complete` to false and add a stable, secret-safe entry to `errors`. Successful providers remain in `providers`. Default mode exits 0 for partial failures. `--strict` exits 1.

No `.env` or separate credentials are required. The tool uses existing local CLI logins and never invokes a model.

## Usage dashboard (Ruby)

`ruby/` adds a history collector and burn-down dashboard on top of this CLI. It never changes the CLI contract above and never calls a provider CLI directly — it only runs `agent-usage-cli` itself on a schedule. See `ruby/AGENTS.md` for the full cheatsheet.

```bash
cd ruby && bundle install
bin/collector           # one collection into ~/Library/Application Support/agent-usage-cli/usage.sqlite3
bin/server               # http://127.0.0.1:4570
bin/install-services     # launchd: collect every 15m, keep the server running
bin/uninstall-services   # stop the launchd services (keeps the database)
```

`AGENT_USAGE_DB` overrides the SQLite path. The dashboard ranks providers by remaining allowance percentage vs. ideal pace on each provider's primary window (Claude `seven_day`, Codex `rateLimits.rateLimits.primary`, Grok `currentPeriod`).
