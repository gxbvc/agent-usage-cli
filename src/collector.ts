import { normalizeProviderError } from "./errors.js";
import { getClaudeUsage } from "./providers/claude.js";
import { getCodexUsage } from "./providers/codex.js";
import { getGrokUsage } from "./providers/grok.js";
import { PROVIDERS, type ProviderAdapter, type ProviderName, type UsageEnvelope } from "./types.js";

export const providerAdapters: Record<ProviderName, ProviderAdapter> = {
  claude: getClaudeUsage,
  codex: getCodexUsage,
  grok: getGrokUsage,
};

export interface CollectOptions {
  providers: ProviderName[];
  includeHistory: boolean;
  timeoutMs?: number;
}

export async function collectUsage(
  options: CollectOptions,
  adapters: Record<ProviderName, ProviderAdapter> = providerAdapters,
): Promise<UsageEnvelope> {
  const settled = await Promise.allSettled(
    options.providers.map((provider) => adapters[provider]({
      includeHistory: options.includeHistory,
      timeoutMs: options.timeoutMs,
    })),
  );

  const providers: UsageEnvelope["data"]["providers"] = {};
  const errors: UsageEnvelope["data"]["errors"] = [];
  settled.forEach((result, index) => {
    const provider = options.providers[index];
    if (result.status === "fulfilled") providers[provider] = result.value;
    else errors.push(normalizeProviderError(provider, result.reason));
  });

  return {
    ok: true,
    data: {
      schemaVersion: 1,
      observedAt: new Date().toISOString(),
      complete: errors.length === 0,
      providers,
      errors,
    },
  };
}

export function strictExitCode(envelope: UsageEnvelope, strict: boolean): number {
  return strict && !envelope.data.complete ? 1 : 0;
}

export function parseProviderSelection(values: readonly string[] | undefined): ProviderName[] {
  if (!values || values.length === 0) return [...PROVIDERS];
  const requested = values.flatMap((value) => value.split(","))
    .map((value) => value.trim().toLowerCase())
    .filter(Boolean);
  if (requested.length === 0) throw new Error("At least one provider is required");
  const invalid = requested.find((provider) => !PROVIDERS.includes(provider as ProviderName));
  if (invalid) throw new Error("Unknown provider selection");
  return [...new Set(requested as ProviderName[])];
}
