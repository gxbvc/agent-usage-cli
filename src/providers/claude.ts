import { ProviderFailure } from "../errors.js";
import { isObject, optionalObject, pickDefined, toIsoTimestamp } from "../normalize.js";
import { parseVersion, runCommand } from "../process.js";
import type { ProviderOptions, ProviderResult } from "../types.js";

const USAGE_URL = "https://api.anthropic.com/api/oauth/usage";
const WINDOW_KEYS = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"] as const;

export function normalizeClaudeUsage(value: unknown): Record<string, unknown> {
  if (!isObject(value)) throw new ProviderFailure("INVALID_RESPONSE", "Claude returned an invalid usage response");

  const windows: Record<string, unknown> = {};
  for (const key of WINDOW_KEYS) {
    const window = optionalObject(value[key]);
    if (!window) continue;
    const normalized: Record<string, unknown> = {};
    if (window.utilization !== undefined) normalized.utilization = window.utilization;
    if (window.resets_at !== undefined) normalized.resetsAt = toIsoTimestamp(window.resets_at) ?? window.resets_at;
    windows[key] = normalized;
  }

  const usage: Record<string, unknown> = { windows };
  if (value.extra_usage !== undefined) usage.extraUsage = value.extra_usage;
  return usage;
}

export async function getClaudeUsage(options: ProviderOptions): Promise<ProviderResult> {
  const timeoutMs = options.timeoutMs;
  const [versionResult, authResult] = await Promise.all([
    runCommand("claude", ["--version"], { timeoutMs }),
    runCommand("claude", ["auth", "status", "--json"], { timeoutMs }),
  ]);

  let auth: Record<string, unknown>;
  try {
    auth = JSON.parse(authResult.stdout) as Record<string, unknown>;
  } catch {
    throw new ProviderFailure("INVALID_RESPONSE", "Claude returned an invalid authentication response");
  }
  if (!isObject(auth)) throw new ProviderFailure("INVALID_RESPONSE", "Claude returned an invalid authentication response");
  if (auth.loggedIn !== true) throw new ProviderFailure("AUTH_NOT_LOGGED_IN", "Claude Code is not logged in");
  if (process.platform !== "darwin") {
    throw new ProviderFailure("UNSUPPORTED_PLATFORM", "Claude OAuth usage requires the macOS Keychain");
  }

  let credentialResult;
  try {
    credentialResult = await runCommand(
      "security",
      ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
      { timeoutMs },
    );
  } catch {
    throw new ProviderFailure("KEYCHAIN_UNAVAILABLE", "Claude Code credentials could not be read from the macOS Keychain");
  }

  let credential: unknown;
  try {
    credential = JSON.parse(credentialResult.stdout);
  } catch {
    throw new ProviderFailure("AUTH_UNAVAILABLE", "Claude Code credentials are not in the expected format");
  }
  const token = optionalObject(optionalObject(credential)?.claudeAiOauth)?.accessToken;
  if (typeof token !== "string" || !token) {
    throw new ProviderFailure("AUTH_UNAVAILABLE", "Claude Code OAuth access is unavailable");
  }

  let response: Response;
  try {
    response = await fetch(USAGE_URL, {
      headers: {
        authorization: `Bearer ${token}`,
        "anthropic-beta": "oauth-2025-04-20",
      },
      signal: AbortSignal.timeout(timeoutMs ?? 20_000),
    });
  } catch (error) {
    if (error instanceof DOMException && error.name === "TimeoutError") {
      throw new ProviderFailure("TIMEOUT", "Claude did not respond before the timeout");
    }
    throw new ProviderFailure("NETWORK_ERROR", "Claude usage could not be reached");
  }
  if (response.status === 401 || response.status === 403) {
    throw new ProviderFailure("AUTH_REJECTED", "Claude Code OAuth access was rejected");
  }
  if (!response.ok) throw new ProviderFailure("HTTP_ERROR", `Claude usage returned HTTP ${response.status}`);

  let rawUsage: unknown;
  try {
    rawUsage = await response.json();
  } catch {
    throw new ProviderFailure("INVALID_RESPONSE", "Claude returned invalid usage JSON");
  }

  return {
    cli: { command: "claude", version: parseVersion(versionResult.stdout) ?? "unknown" },
    account: pickDefined(auth, [
      "loggedIn",
      "authMethod",
      "apiProvider",
      "email",
      "orgId",
      "orgName",
      "subscriptionType",
    ]),
    usage: normalizeClaudeUsage(rawUsage),
  };
}
