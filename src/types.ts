export const PROVIDERS = ["claude", "codex", "grok"] as const;

export type ProviderName = (typeof PROVIDERS)[number];

export interface CliMetadata {
  command: string;
  version: string;
}

export interface ProviderError {
  provider: ProviderName;
  code: string;
  message: string;
}

export interface ProviderResult {
  cli: CliMetadata;
  account?: Record<string, unknown>;
  usage?: Record<string, unknown>;
}

export interface UsageData {
  complete: boolean;
  providers: Partial<Record<ProviderName, ProviderResult>>;
  errors: ProviderError[];
}

export interface UsageEnvelope {
  ok: true;
  data: UsageData;
}

export interface ProviderOptions {
  includeHistory: boolean;
  timeoutMs?: number;
}

export type ProviderAdapter = (options: ProviderOptions) => Promise<ProviderResult>;
