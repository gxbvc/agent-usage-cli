import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { normalizeClaudeUsage } from "../providers/claude.js";
import { normalizeCodexResponses } from "../providers/codex.js";
import { normalizeGrokResponses } from "../providers/grok.js";

function fixture(name: string): Record<string, unknown> {
  return JSON.parse(readFileSync(new URL(`../../fixtures/${name}`, import.meta.url), "utf8")) as Record<string, unknown>;
}

test("normalizes Claude windows and extra usage", () => {
  const usage = normalizeClaudeUsage(fixture("claude-usage.json"));
  const windows = usage.windows as Record<string, Record<string, unknown>>;
  assert.equal(windows.five_hour.utilization, 12.5);
  assert.equal(windows.five_hour.resetsAt, "2026-08-19T18:00:00.000Z");
  assert.equal(windows.seven_day_opus, undefined);
  assert.deepEqual(usage.extraUsage, { is_enabled: true, monthly_limit: 5000, used_credits: 125 });
});

test("normalizes Codex resets and omits history by default", () => {
  const input = fixture("codex-responses.json");
  const result = normalizeCodexResponses(input.account, input.rateLimits, input.usage, false);
  assert.deepEqual(result.account, {
    type: "chatgpt",
    email: "person@example.com",
    planType: "pro",
    requiresOpenaiAuth: true,
  });
  const usage = result.usage as Record<string, unknown>;
  assert.equal(usage.dailyUsageBuckets, undefined);
  const limits = usage.rateLimits as Record<string, Record<string, Record<string, unknown>>>;
  assert.equal(limits.rateLimits.primary.resetsAt, "2026-08-19T16:00:00.000Z");
});

test("includes Codex daily history only when requested", () => {
  const input = fixture("codex-responses.json");
  const result = normalizeCodexResponses(input.account, input.rateLimits, input.usage, true);
  const buckets = result.usage?.dailyUsageBuckets as unknown[];
  assert.equal(buckets.length, 2);
});

test("normalizes the live Grok billing nesting and every useful field", () => {
  const input = fixture("grok-responses.json");
  const result = normalizeGrokResponses(input.auth, input.billing);
  assert.deepEqual(result.account, {
    authenticated: true,
    email: "person@example.com",
    auth_mode: "oauth",
    team_id: "team_123",
    team_name: "Example",
    team_role: "member",
    is_zdr: false,
    coding_data_retention_opt_out: true,
    show_resolved_model: true,
    subscription_tier: "supergrok",
  });
  assert.deepEqual(result.usage, {
    creditUsagePercent: 73.5,
    remainingPercent: 73.5,
    usedPercent: 26.5,
    currentPeriod: {
      type: "weekly",
      start: "2026-08-01T00:00:00.000Z",
      end: "2026-08-08T00:00:00.000Z",
    },
    onDemand: {
      cap: { currency: "USD", cents: 2500, dollars: 25 },
      used: { currency: "USD", cents: 499, dollars: 4.99 },
    },
    prepaidBalance: { currency: "USD", cents: 1234, dollars: 12.34 },
    isUnifiedBillingUser: true,
    billingPeriodStart: "2026-07-01T00:00:00.000Z",
    billingPeriodEnd: "2026-08-01T00:00:00.000Z",
    subscription_tier: "supergrok",
  });
});

test("does not invent Grok numeric values when billing fields are absent", () => {
  const result = normalizeGrokResponses({ authenticated: true, meta: {} }, { config: {} });
  assert.equal(result.usage?.creditUsagePercent, undefined);
  assert.equal(result.usage?.remainingPercent, undefined);
  assert.equal(result.usage?.usedPercent, undefined);
  assert.equal(result.usage?.prepaidBalance, undefined);
});
