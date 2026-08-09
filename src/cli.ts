import { Command, CommanderError } from "commander";
import { collectUsage, parseProviderSelection, strictExitCode } from "./collector.js";

interface CliOptions {
  provider: string[];
  includeHistory: boolean;
  pretty: boolean;
  strict: boolean;
}

export function buildProgram(): Command {
  const program = new Command();
  program
    .name("agent-usage-cli")
    .description("Read local Claude Code, Codex, and Grok Build subscription usage")
    .version("1.0.0")
    .option(
      "-p, --provider <provider>",
      "provider to query (claude, codex, or grok; repeat or use commas)",
      (value: string, previous: string[]) => [...previous, value],
      [],
    )
    .option("--include-history", "include Codex daily token usage buckets", false)
    .option("--pretty", "indent JSON output", false)
    .option("--strict", "exit nonzero when any selected provider fails", false)
    .action(async (options: CliOptions) => {
      const providers = parseProviderSelection(options.provider);
      const envelope = await collectUsage({ providers, includeHistory: options.includeHistory });
      process.stdout.write(`${JSON.stringify(envelope, null, options.pretty ? 2 : undefined)}\n`);
      process.exitCode = strictExitCode(envelope, options.strict);
    });
  return program;
}

const program = buildProgram();
program.exitOverride();
program.configureOutput({ writeErr: () => undefined });

program.parseAsync().catch((error: unknown) => {
  if (error instanceof CommanderError && ["commander.helpDisplayed", "commander.version"].includes(error.code)) return;
  process.stdout.write(`${JSON.stringify({ ok: false, error: "Invalid command arguments", code: "INVALID_ARGUMENT" })}\n`);
  process.exitCode = 1;
});
