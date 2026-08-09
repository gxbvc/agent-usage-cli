import { execFile, spawn, type ChildProcessWithoutNullStreams } from "node:child_process";

const DEFAULT_TIMEOUT_MS = 20_000;
const TERMINATION_GRACE_MS = 100;
const KILL_WAIT_MS = 500;
const MAX_OUTPUT_BYTES = 2 * 1024 * 1024;

export type ProcessFailureKind = "not_found" | "timeout" | "failed" | "invalid_response" | "protocol";

export class ProcessFailure extends Error {
  constructor(
    public readonly kind: ProcessFailureKind,
    public readonly command: string,
  ) {
    super(`${command} subprocess ${kind}`);
    this.name = "ProcessFailure";
  }
}

export interface CommandResult {
  stdout: string;
}

export function runCommand(
  command: string,
  args: readonly string[],
  options: { timeoutMs?: number; input?: string } = {},
): Promise<CommandResult> {
  return new Promise((resolve, reject) => {
    let timedOut = false;
    let forceKillTimer: NodeJS.Timeout | undefined;
    let cleanupDeadlineTimer: NodeJS.Timeout | undefined;
    const child = execFile(
      command,
      [...args],
      {
        maxBuffer: MAX_OUTPUT_BYTES,
        encoding: "utf8",
      },
      (error, stdout) => {
        clearTimeout(timeoutTimer);
        if (forceKillTimer) clearTimeout(forceKillTimer);
        if (cleanupDeadlineTimer) clearTimeout(cleanupDeadlineTimer);
        if (timedOut) {
          reject(new ProcessFailure("timeout", command));
          return;
        }
        if (!error) {
          resolve({ stdout });
          return;
        }

        const systemError = error as NodeJS.ErrnoException;
        if (systemError.code === "ENOENT") reject(new ProcessFailure("not_found", command));
        else reject(new ProcessFailure("failed", command));
      },
    );

    const timeoutTimer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGTERM");
      forceKillTimer = setTimeout(() => {
        if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
      }, TERMINATION_GRACE_MS);
      cleanupDeadlineTimer = setTimeout(() => {
        if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
        reject(new ProcessFailure("timeout", command));
      }, TERMINATION_GRACE_MS + KILL_WAIT_MS);
    }, options.timeoutMs ?? DEFAULT_TIMEOUT_MS);

    child.stdin?.end(options.input);
  });
}

interface RpcResponse {
  id?: number | string;
  result?: unknown;
  error?: unknown;
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

export class JsonLineRpcClient {
  private readonly child: ChildProcessWithoutNullStreams;
  private readonly pending = new Map<number | string, {
    resolve: (value: unknown) => void;
    reject: (error: Error) => void;
  }>();
  private readonly exited: Promise<void>;
  private resolveExited!: () => void;
  private buffer = "";
  private failed = false;
  private processExited = false;
  private closePromise?: Promise<void>;
  private readonly timeout: NodeJS.Timeout;

  constructor(
    private readonly command: string,
    args: readonly string[],
    timeoutMs = DEFAULT_TIMEOUT_MS,
  ) {
    this.exited = new Promise((resolve) => { this.resolveExited = resolve; });
    this.child = spawn(command, [...args], { stdio: ["pipe", "pipe", "pipe"] });
    this.child.stdout.setEncoding("utf8");
    this.child.stdout.on("data", (chunk: string) => this.consume(chunk));
    this.child.stdin.on("error", () => {
      this.failAll(new ProcessFailure("failed", command));
    });
    // Drain stderr so a verbose provider cannot block. It is intentionally never exposed.
    this.child.stderr.resume();
    this.child.once("error", (error: NodeJS.ErrnoException) => {
      this.processExited = true;
      this.failAll(new ProcessFailure(error.code === "ENOENT" ? "not_found" : "failed", command));
      this.resolveExited();
    });
    this.child.once("exit", (code) => {
      this.processExited = true;
      this.resolveExited();
      if (!this.failed && !this.closePromise && this.pending.size > 0) {
        this.failAll(new ProcessFailure(code === 0 ? "protocol" : "failed", command));
      }
    });
    this.timeout = setTimeout(() => {
      void this.close(new ProcessFailure("timeout", command)).catch(() => undefined);
    }, timeoutMs);
  }

  request(id: number | string, method: string, params: unknown): Promise<unknown> {
    if (this.failed || this.closePromise) return Promise.reject(new ProcessFailure("failed", this.command));

    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.write({ jsonrpc: "2.0", id, method, params });
    });
  }

  notify(method: string, params?: unknown): void {
    if (this.failed || this.closePromise) return;
    this.write(params === undefined ? { jsonrpc: "2.0", method } : { jsonrpc: "2.0", method, params });
  }

  close(pendingError = new ProcessFailure("failed", this.command)): Promise<void> {
    this.closePromise ??= this.terminate().then(
      () => {
        if (this.pending.size > 0) this.failAll(pendingError);
      },
      (error: unknown) => {
        if (this.pending.size > 0) this.failAll(pendingError);
        throw error;
      },
    );
    return this.closePromise;
  }

  private async terminate(): Promise<void> {
    clearTimeout(this.timeout);
    if (!this.child.stdin.destroyed) this.child.stdin.end();
    if (this.hasExited()) return;

    this.child.kill("SIGTERM");
    await Promise.race([this.exited, delay(TERMINATION_GRACE_MS)]);
    if (this.hasExited()) return;

    this.child.kill("SIGKILL");
    await Promise.race([this.exited, delay(KILL_WAIT_MS)]);
    if (!this.hasExited()) throw new ProcessFailure("failed", this.command);
  }

  private hasExited(): boolean {
    return this.processExited || this.child.exitCode !== null || this.child.signalCode !== null;
  }

  private write(message: object): void {
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  private consume(chunk: string): void {
    this.buffer += chunk;
    if (this.buffer.length > MAX_OUTPUT_BYTES) {
      this.failAll(new ProcessFailure("invalid_response", this.command));
      void this.close();
      return;
    }

    let newline = this.buffer.indexOf("\n");
    while (newline >= 0) {
      const line = this.buffer.slice(0, newline).trim();
      this.buffer = this.buffer.slice(newline + 1);
      if (line) this.consumeLine(line);
      newline = this.buffer.indexOf("\n");
    }
  }

  private consumeLine(line: string): void {
    let message: RpcResponse;
    try {
      message = JSON.parse(line) as RpcResponse;
    } catch {
      return; // Providers can write non-protocol status lines to stdout.
    }

    if (message.id === undefined) return;
    const waiter = this.pending.get(message.id);
    if (!waiter) return;
    this.pending.delete(message.id);
    if (message.error !== undefined) waiter.reject(new ProcessFailure("protocol", this.command));
    else waiter.resolve(message.result);
  }

  private failAll(error: Error): void {
    if (this.failed) return;
    this.failed = true;
    clearTimeout(this.timeout);
    for (const waiter of this.pending.values()) waiter.reject(error);
    this.pending.clear();
  }
}

export function parseVersion(stdout: string): string | undefined {
  const match = stdout.match(/\bv?(\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.-]+)?)/);
  if (match?.[1]) return match[1];
  const fallback = stdout.trim().split(/\r?\n/, 1)[0]?.slice(0, 200);
  return fallback || undefined;
}
