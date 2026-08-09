import assert from "node:assert/strict";
import test from "node:test";
import { collectUsage, parseProviderSelection, strictExitCode } from "../collector.js";
import { ProviderFailure } from "../errors.js";
import type { ProviderAdapter, ProviderName } from "../types.js";

const success: ProviderAdapter = async () => ({
  cli: { command: "test", version: "1.2.3" },
  account: { plan: "pro" },
  usage: { windows: {} },
});

function adapters(overrides: Partial<Record<ProviderName, ProviderAdapter>> = {}): Record<ProviderName, ProviderAdapter> {
  return { claude: success, codex: success, grok: success, ...overrides };
}

test("provider selection accepts repeated and comma-separated values", () => {
  assert.deepEqual(parseProviderSelection(["codex,grok", "claude", "codex"]), ["codex", "grok", "claude"]);
  assert.deepEqual(parseProviderSelection(undefined), ["claude", "codex", "grok"]);
  assert.throws(() => parseProviderSelection(["other"]), /Unknown provider selection/);
});

test("partial failures preserve successful providers in a stable envelope", async () => {
  const envelope = await collectUsage(
    { providers: ["claude", "codex", "grok"], includeHistory: false },
    adapters({ codex: async () => { throw new ProviderFailure("AUTH_NOT_LOGGED_IN", "Codex is not logged in"); } }),
  );

  assert.equal(envelope.ok, true);
  assert.equal(envelope.data.complete, false);
  assert.deepEqual(Object.keys(envelope.data.providers), ["claude", "grok"]);
  assert.deepEqual(envelope.data.errors, [{
    provider: "codex",
    code: "AUTH_NOT_LOGGED_IN",
    message: "Codex is not logged in",
  }]);
  assert.equal(strictExitCode(envelope, false), 0);
  assert.equal(strictExitCode(envelope, true), 1);
});

test("all selected providers are started concurrently", async () => {
  const started: ProviderName[] = [];
  let release!: () => void;
  const gate = new Promise<void>((resolve) => { release = resolve; });
  const waiting = (name: ProviderName): ProviderAdapter => async () => {
    started.push(name);
    if (started.length === 3) release();
    await gate;
    return { cli: { command: name, version: "1.0.0" } };
  };

  const envelope = await collectUsage(
    { providers: ["claude", "codex", "grok"], includeHistory: false },
    { claude: waiting("claude"), codex: waiting("codex"), grok: waiting("grok") },
  );
  assert.deepEqual(started, ["claude", "codex", "grok"]);
  assert.equal(envelope.data.complete, true);
});
