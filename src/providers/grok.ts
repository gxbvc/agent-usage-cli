import { ProviderFailure } from "../errors.js";
import { centsToDollars, isObject, numberValue, optionalObject, pickDefined, toIsoTimestamp } from "../normalize.js";
import { JsonLineRpcClient, parseVersion, runCommand } from "../process.js";
import type { ProviderOptions, ProviderResult } from "../types.js";

function money(value: unknown): Record<string, unknown> | undefined {
  const object = optionalObject(value);
  if (!object) return undefined;
  const cents = numberValue(object.val);
  const dollars = centsToDollars(object.val);
  const result = pickDefined(object, ["currency"]);
  if (cents !== undefined) result.cents = cents;
  if (dollars !== undefined) result.dollars = dollars;
  return Object.keys(result).length > 0 ? result : undefined;
}

function period(value: unknown): Record<string, unknown> | undefined {
  const object = optionalObject(value);
  if (!object) return undefined;
  const result = pickDefined(object, ["type"]);
  if (object.start !== undefined) result.start = toIsoTimestamp(object.start) ?? object.start;
  if (object.end !== undefined) result.end = toIsoTimestamp(object.end) ?? object.end;
  return result;
}

export function normalizeGrokResponses(
  authValue: unknown,
  billingValue: unknown,
): Pick<ProviderResult, "account" | "usage"> {
  if (!isObject(authValue) || !isObject(billingValue)) {
    throw new ProviderFailure("INVALID_RESPONSE", "Grok returned an invalid account or billing response");
  }
  if (authValue.authenticated !== true) throw new ProviderFailure("AUTH_NOT_LOGGED_IN", "Grok Build is not logged in");

  const meta = optionalObject(authValue.meta) ?? {};
  const account: Record<string, unknown> = {
    authenticated: true,
    ...pickDefined(meta, [
      "email",
      "auth_mode",
      "team_id",
      "team_name",
      "team_role",
      "is_zdr",
      "coding_data_retention_opt_out",
      "show_resolved_model",
      "subscription_tier",
    ]),
  };

  const config = optionalObject(billingValue.config) ?? {};
  // config.creditUsagePercent is the percent of the plan's weekly allowance
  // already USED (100 = fully used, 0 remaining), matching what `/usage`
  // shows in Grok Build. Do not treat it as remaining allowance.
  const creditUsagePercent = numberValue(config.creditUsagePercent);
  const usage: Record<string, unknown> = {};
  if (creditUsagePercent !== undefined) {
    usage.creditUsagePercent = creditUsagePercent;
    usage.usedPercent = creditUsagePercent;
    usage.remainingPercent = 100 - creditUsagePercent;
  }

  const currentPeriod = period(config.currentPeriod);
  if (currentPeriod) usage.currentPeriod = currentPeriod;

  const onDemandCap = money(config.onDemandCap);
  const onDemandUsed = money(config.onDemandUsed);
  if (onDemandCap || onDemandUsed) {
    usage.onDemand = {};
    if (onDemandCap) (usage.onDemand as Record<string, unknown>).cap = onDemandCap;
    if (onDemandUsed) (usage.onDemand as Record<string, unknown>).used = onDemandUsed;
  }
  const prepaidBalance = money(config.prepaidBalance);
  if (prepaidBalance) usage.prepaidBalance = prepaidBalance;

  if (config.isUnifiedBillingUser !== undefined) usage.isUnifiedBillingUser = config.isUnifiedBillingUser;
  if (config.billingPeriodStart !== undefined) {
    usage.billingPeriodStart = toIsoTimestamp(config.billingPeriodStart) ?? config.billingPeriodStart;
  }
  if (config.billingPeriodEnd !== undefined) {
    usage.billingPeriodEnd = toIsoTimestamp(config.billingPeriodEnd) ?? config.billingPeriodEnd;
  }
  if (billingValue.subscription_tier !== undefined) usage.subscription_tier = billingValue.subscription_tier;

  return { account, usage };
}

export async function getGrokUsage(options: ProviderOptions): Promise<ProviderResult> {
  const rpc = new JsonLineRpcClient("grok", ["agent", "stdio"], options.timeoutMs);
  try {
    await rpc.request(1, "initialize", {
      protocolVersion: 1,
      capabilities: {
        fs: { readTextFile: false, writeTextFile: false },
        terminal: false,
      },
      clientInfo: { name: "agent-usage-cli", version: "1.0.0" },
    });
    const [authValue, billingValue, versionResult] = await Promise.all([
      rpc.request(2, "_x.ai/auth/check_subscription", {}),
      rpc.request(3, "_x.ai/billing", {}),
      runCommand("grok", ["--version"], { timeoutMs: options.timeoutMs }),
    ]);
    const normalized = normalizeGrokResponses(authValue, billingValue);
    return {
      cli: { command: "grok", version: parseVersion(versionResult.stdout) ?? "unknown" },
      ...normalized,
    };
  } finally {
    await rpc.close();
  }
}
