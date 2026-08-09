import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { JsonLineRpcClient, ProcessFailure, runCommand } from "../process.js";

function isAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function readPid(path: string): number {
  return Number(readFileSync(path, "utf8"));
}

async function withPidFile(run: (pidFile: string) => Promise<void>): Promise<void> {
  const directory = mkdtempSync(join(tmpdir(), "agent-usage-process-"));
  const pidFile = join(directory, "pid");
  try {
    await run(pidFile);
  } finally {
    try {
      const pid = readPid(pidFile);
      if (isAlive(pid)) process.kill(pid, "SIGKILL");
    } catch {
      // The child can time out before writing its PID on a heavily loaded machine.
    }
    rmSync(directory, { recursive: true, force: true });
  }
}

const HANGING_CHILD = `
  const fs = require("node:fs");
  fs.writeFileSync(process.argv[1], String(process.pid));
  process.on("SIGTERM", () => {});
  setInterval(() => {}, 1000);
`;

test("runCommand force-kills a child that ignores SIGTERM", async () => {
  await withPidFile(async (pidFile) => {
    const startedAt = Date.now();
    await assert.rejects(
      runCommand(process.execPath, ["-e", HANGING_CHILD, pidFile], { timeoutMs: 100 }),
      (error: unknown) => error instanceof ProcessFailure && error.kind === "timeout",
    );
    const pid = readPid(pidFile);
    assert.equal(isAlive(pid), false);
    assert.ok(Date.now() - startedAt < 2_000, "timeout cleanup must be bounded");
  });
});

test("JSON-line timeout cleans up a malformed child that ignores SIGTERM", async () => {
  await withPidFile(async (pidFile) => {
    const script = `
      const fs = require("node:fs");
      fs.writeFileSync(process.argv[1], String(process.pid));
      process.on("SIGTERM", () => {});
      process.stdout.write("not-json\\n");
      process.stdin.resume();
      setInterval(() => {}, 1000);
    `;
    const client = new JsonLineRpcClient(process.execPath, ["-e", script, pidFile], 100);
    await assert.rejects(
      client.request(1, "test", {}),
      (error: unknown) => error instanceof ProcessFailure && error.kind === "timeout",
    );
    assert.equal(isAlive(readPid(pidFile)), false, "timeout must reject only after cleanup");
    await client.close();
  });
});

test("JSON-line protocol errors still receive bounded force-kill cleanup", async () => {
  await withPidFile(async (pidFile) => {
    const script = `
      const fs = require("node:fs");
      const readline = require("node:readline");
      fs.writeFileSync(process.argv[1], String(process.pid));
      process.on("SIGTERM", () => {});
      setInterval(() => {}, 1000);
      readline.createInterface({ input: process.stdin }).once("line", (line) => {
        const request = JSON.parse(line);
        process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: request.id, error: { code: -1 } }) + "\\n");
      });
    `;
    const client = new JsonLineRpcClient(process.execPath, ["-e", script, pidFile], 1_000);
    await assert.rejects(
      client.request(1, "test", {}),
      (error: unknown) => error instanceof ProcessFailure && error.kind === "protocol",
    );
    const startedAt = Date.now();
    await client.close();
    assert.equal(isAlive(readPid(pidFile)), false);
    assert.ok(Date.now() - startedAt < 1_000, "close cleanup must be bounded");
  });
});
