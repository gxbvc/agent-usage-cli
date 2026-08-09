import { ProcessFailure } from "./process.js";
import type { ProviderError, ProviderName } from "./types.js";

export class ProviderFailure extends Error {
  constructor(
    public readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "ProviderFailure";
  }
}

const LABELS: Record<ProviderName, string> = {
  claude: "Claude",
  codex: "Codex",
  grok: "Grok",
};

export function normalizeProviderError(provider: ProviderName, error: unknown): ProviderError {
  if (error instanceof ProviderFailure) {
    return { provider, code: error.code, message: error.message };
  }

  if (error instanceof ProcessFailure) {
    const label = LABELS[provider];
    const mapping: Record<ProcessFailure["kind"], { code: string; message: string }> = {
      not_found: { code: "CLI_NOT_FOUND", message: `${error.command} is not installed or is not on PATH` },
      timeout: { code: "TIMEOUT", message: `${label} did not respond before the timeout` },
      failed: { code: "CLI_FAILED", message: `${label} CLI command failed` },
      invalid_response: { code: "INVALID_RESPONSE", message: `${label} returned an invalid response` },
      protocol: { code: "PROTOCOL_ERROR", message: `${label} protocol request failed` },
    };
    return { provider, ...mapping[error.kind] };
  }

  return {
    provider,
    code: "UNEXPECTED_ERROR",
    message: `${LABELS[provider]} usage could not be read`,
  };
}
