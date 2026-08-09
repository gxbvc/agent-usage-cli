import assert from "node:assert/strict";
import test from "node:test";
import { normalizeProviderError } from "../errors.js";
import { ProcessFailure } from "../process.js";

test("unexpected errors do not expose messages or tokens", () => {
  const secret = "sk-secret-token-value";
  const normalized = normalizeProviderError("claude", new Error(`Authorization: Bearer ${secret}`));
  assert.deepEqual(normalized, {
    provider: "claude",
    code: "UNEXPECTED_ERROR",
    message: "Claude usage could not be read",
  });
  assert.equal(JSON.stringify(normalized).includes(secret), false);
});

test("subprocess errors use stable secret-safe codes", () => {
  assert.deepEqual(normalizeProviderError("codex", new ProcessFailure("failed", "codex")), {
    provider: "codex",
    code: "CLI_FAILED",
    message: "Codex CLI command failed",
  });
  assert.equal(normalizeProviderError("grok", new ProcessFailure("timeout", "grok")).code, "TIMEOUT");
});
