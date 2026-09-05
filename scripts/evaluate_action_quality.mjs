#!/usr/bin/env node

import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const fixtures = JSON.parse(
  readFileSync(resolve(root, "Tests/Fixtures/action-quality.json"), "utf8"),
);
const requested = new Set(process.argv.slice(2));
const selected = requested.size
  ? fixtures.filter(({ name }) => requested.has(name))
  : fixtures;

if (!selected.length) {
  console.error("No matching fixture names.");
  process.exit(2);
}

console.error(
  "Opt-in evaluation: this invokes the configured Copilot CLI once per case.",
);

let failed = false;
for (const fixture of selected) {
  const result = spawnSync(
    resolve(root, "scripts/swift.sh"),
    ["run", "Mancia", "--complete", fixture.action],
    {
      cwd: root,
      input: fixture.input,
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
    },
  );

  console.log(`\n=== ${fixture.name} (${fixture.action}) ===`);
  if (result.status !== 0) {
    failed = true;
    console.log(`FAILED (exit ${result.status})`);
    process.stderr.write(result.stderr);
    continue;
  }

  const output = result.stdout;
  process.stdout.write(output.endsWith("\n") ? output : `${output}\n`);

  for (const literal of fixture.requiredLiterals) {
    const present = output.includes(literal);
    failed ||= !present;
    console.log(`${present ? "PASS" : "FAIL"} required literal: ${literal}`);
  }
  for (const literal of fixture.forbiddenLiterals) {
    const absent = !output.includes(literal);
    failed ||= !absent;
    console.log(`${absent ? "PASS" : "FAIL"} forbidden literal: ${literal}`);
  }
  console.log(`REVIEW: ${fixture.review}`);
}

process.exitCode = failed ? 1 : 0;
