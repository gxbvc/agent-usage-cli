type JsonObject = Record<string, unknown>;

export function isObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function optionalObject(value: unknown): JsonObject | undefined {
  return isObject(value) ? value : undefined;
}

export function pickDefined(source: JsonObject, keys: readonly string[]): JsonObject {
  return Object.fromEntries(keys.filter((key) => source[key] !== undefined).map((key) => [key, source[key]]));
}

export function toIsoTimestamp(value: unknown): string | undefined {
  if (typeof value === "number" && Number.isFinite(value)) {
    const milliseconds = value < 100_000_000_000 ? value * 1000 : value;
    const date = new Date(milliseconds);
    return Number.isNaN(date.valueOf()) ? undefined : date.toISOString();
  }
  if (typeof value === "string" && value.trim()) {
    const date = new Date(value);
    return Number.isNaN(date.valueOf()) ? undefined : date.toISOString();
  }
  return undefined;
}

export function normalizeResetFields(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(normalizeResetFields);
  if (!isObject(value)) return value;

  const result: JsonObject = {};
  for (const [key, child] of Object.entries(value)) {
    if (key === "resetsAt" || key === "resets_at") {
      result.resetsAt = toIsoTimestamp(child) ?? child;
    } else {
      result[key] = normalizeResetFields(child);
    }
  }
  return result;
}

export function centsToDollars(value: unknown): number | undefined {
  if (typeof value !== "number" || !Number.isFinite(value)) return undefined;
  return value / 100;
}

export function numberValue(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}
