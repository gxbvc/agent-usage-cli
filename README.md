# agent-usage-cli

Read subscription usage and basic account details from locally logged-in Claude Code, Codex, and Grok Build CLIs. The command is read-only and returns one JSON envelope.

## Prerequisites

- Node.js 20 or newer
- Any provider CLI you want to query on `PATH`
- A local login for each selected provider
- macOS Keychain access for Claude usage

The command does not need an `.env` file or separate API credentials. It does not call a model.

## Setup

```bash
npm install
npm run build
npm link
```

## Usage

```bash
agent-usage-cli
agent-usage-cli --provider claude
agent-usage-cli --provider claude,codex
agent-usage-cli --provider codex --provider grok
agent-usage-cli --include-history
agent-usage-cli --pretty
agent-usage-cli --strict
```

Options:

- `--provider <claude|codex|grok>` selects providers. Repeat the option or use commas. The default selects all three.
- `--include-history` includes Codex `dailyUsageBuckets`. The Codex summary is always included.
- `--pretty` indents the JSON. The default output is compact, single-line JSON.
- `--strict` exits with status 1 if any selected provider fails. Without it, partial failures exit successfully.

## Output

Successful queries and partial results use this envelope:

```json
{"ok":true,"data":{"complete":false,"providers":{"claude":{"cli":{"command":"claude","version":"1.2.3"},"account":{},"usage":{}}},"errors":[{"provider":"codex","code":"CLI_NOT_FOUND","message":"codex is not installed or is not on PATH"}]}}
```

`complete` is false when a selected provider fails. Successful provider data remains available in `providers`. Each provider keeps separate usage windows rather than combining them into one total. Missing values are omitted instead of reported as zero.

## How it works

- Claude account metadata comes from `claude auth status --json`. The OAuth token is read from the macOS Keychain with `security` and used only in memory for the Anthropic usage request.
- Codex uses the newline JSON protocol from `codex app-server` to read the account, rate limits, and usage summary.
- Grok uses newline JSON-RPC from `grok agent stdio` to read subscription and billing data. Grok reports `config.creditUsagePercent` as the remaining weekly allowance shown by `/usage`. The output preserves that value as `creditUsagePercent` and `remainingPercent`, then derives `usedPercent` as `100 - remainingPercent`. It also includes the plan tier, period dates, unified billing status, and credit amounts in cents and dollars when reported.
- Each provider CLI version is read with `--version`. These commands do not start model inference.
- Providers run concurrently. Subprocesses and network calls have a 20-second timeout. Timed-out children receive a short graceful shutdown and then a forced kill if needed.

The tool does not print or persist tokens, authorization headers, raw authentication payloads, or provider stderr.

## Development

```bash
npm test
npm run build
node dist/cli.js --help
```

Tests use fixtures, fake adapters, and temporary local Node child processes. They do not access real credentials or run provider CLIs.
