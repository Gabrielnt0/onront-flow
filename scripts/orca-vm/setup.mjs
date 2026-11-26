#!/usr/bin/env node
// Idempotent workspace setup for Orca per-workspace environments.
//
// Installs the locked Node dependencies exactly once per package-lock.json
// revision. Never touches backend/data or any other persisted project data
// (see .codex/data-persistence-contract.md).
//
// Progress goes to stderr; stdout stays clean for tooling.

import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const lockPath = join(repoRoot, "package-lock.json");
const nodeModules = join(repoRoot, "node_modules");
const markerPath = join(nodeModules, ".setup-lock-sha256");

const log = (message) => process.stderr.write(`[setup] ${message}\n`);

function sha256(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

if (!existsSync(lockPath)) {
  log(`missing ${lockPath}; cannot install locked dependencies`);
  process.exit(1);
}

const lockSha = sha256(lockPath);
let marker = "";
try {
  marker = readFileSync(markerPath, "utf8").trim();
} catch {}

if (existsSync(join(nodeModules, ".package-lock.json")) && marker === lockSha) {
  log("node_modules already matches package-lock.json; nothing to do");
  process.exit(0);
}

log("running npm ci (locked install)");
const result = spawnSync(
  "npm",
  ["ci", "--no-audit", "--no-fund"],
  {
    cwd: repoRoot,
    stdio: "inherit",
    shell: process.platform === "win32",
  },
);

if (result.error) {
  log(`failed to start npm: ${result.error.message}`);
  process.exit(1);
}
if (result.status !== 0) {
  log(`npm ci failed with status ${result.status}`);
  process.exit(result.status ?? 1);
}

mkdirSync(dirname(markerPath), { recursive: true });
writeFileSync(markerPath, `${lockSha}\n`);
log("dependencies installed");
