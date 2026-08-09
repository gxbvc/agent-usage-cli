import { ProviderFailure } from "../errors.js";
import { isObject, normalizeResetFields, optionalObject, pickDefined } from "../normalize.js";
import { JsonLineRpcClient, parseVersion, runCommand } from "../process.js";
import type { ProviderOptions, ProviderResult } from "../types.js";

export function normalizeCodexResponses(
  accountValue: unknown,
  rateLimitsValue: unknown,
  usageValue: unknown,
  includeHistory: boolean,
): Pick<ProviderResult, "account" | "usage"> {
  if (!isObject(accountValue) || !isObject(rateLimitsValue) || !isObject(usageValue)) {
    throw new ProviderFailure("INVALID_RESPONSE", "Codex returned an invalid account or usage response");
  }

  const rawAccount = optionalObject(accountValue.account) ?? accountValue;
  const account = pickDefined(rawAccount, ["type", "email", "planType"]);
  if (accountValue.requiresOpenaiAuth !== undefined) {
    account.requiresOpenaiAuth = accountValue.requiresOpenaiAuth;
  }

  const usage: Record<string, unknown> = {
    rateLimits: normalizeResetFields(rateLimitsValue),
  };
  if (usageValue.summary !== undefined) usage.summary = normalizeResetFields(usageValue.summary);
  if (includeHistory && usageValue.dailyUsageBuckets !== undefined) {
    usage.dailyUsageBuckets = normalizeResetFields(usageValue.dailyUsageBuckets);
  }

  return { account, usage };
}

export async function getCodexUsage(options: ProviderOptions): Promise<ProviderResult> {
  const rpc = new JsonLineRpcClient("codex", ["app-server"], options.timeoutMs);
  try {
    await rpc.request(1, "initialize", {
      clientInfo: { name: "agent-usage-cli", version: "1.0.0" },
      capabilities: {},
    });
    rpc.notify("initialized", {});
    const [accountValue, rateLimitsValue, usageValue, versionResult] = await Promise.all([
      rpc.request(2, "account/read", { refreshToken: false }),
      rpc.request(3, "account/rateLimits/read", {}),
      rpc.request(4, "account/usage/read", {}),
      runCommand("codex", ["--version"], { timeoutMs: options.timeoutMs }),
    ]);
    const normalized = normalizeCodexResponses(accountValue, rateLimitsValue, usageValue, options.includeHistory);
    return {
      cli: { command: "codex", version: parseVersion(versionResult.stdout) ?? "unknown" },
      ...normalized,
    };
  } finally {
    await rpc.close();
  }
}
