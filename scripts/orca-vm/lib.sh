#!/usr/bin/env bash
# Shared helpers for the Vercel Sandbox per-workspace environment scripts.
# Sourced by the scripts in this directory; never executed directly.

orca_vm_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state_file="${ORCA_VM_STATE_FILE:-${orca_vm_dir}/vercel-sandbox-state.json}"

# json_value <file> <dotted.key>  -> value on stdout, empty when absent
json_value() {
  node -e '
    const fs = require("fs");
    const file = process.argv[1];
    const key = process.argv[2];
    let obj;
    try { obj = JSON.parse(fs.readFileSync(file, "utf8")); } catch { process.exit(2); }
    let value = obj;
    for (const part of key.split(".")) {
      if (value === null || typeof value !== "object") { value = undefined; break; }
      value = value[part];
    }
    process.stdout.write(value === null || value === undefined ? "" : String(value));
  ' "$1" "$2"
}

# state_value <key> -> value from the state file, empty when absent
state_value() {
  if [ -f "$state_file" ]; then
    json_value "$state_file" "$1" || true
  fi
}

# env_value <ENV_NAME> <state_key> <fallback> -> env, then state, then fallback
env_value() {
  local env_name="$1" state_key="$2" fallback="$3"
  local direct="${!env_name:-}"
  if [ -n "$direct" ]; then
    printf '%s' "$direct"
    return 0
  fi
  local from_state
  from_state="$(state_value "$state_key")"
  if [ -n "$from_state" ]; then
    printf '%s' "$from_state"
    return 0
  fi
  printf '%s' "$fallback"
}

# merge_state key=value ... -> merge into the state file, printing nothing
merge_state() {
  node -e '
    const fs = require("fs");
    const file = process.argv[1];
    const pairs = process.argv.slice(2);
    let obj = {};
    try { obj = JSON.parse(fs.readFileSync(file, "utf8")); } catch {}
    for (const pair of pairs) {
      const idx = pair.indexOf("=");
      if (idx < 0) continue;
      obj[pair.slice(0, idx)] = pair.slice(idx + 1);
    }
    fs.writeFileSync(file, JSON.stringify(obj, null, 2) + "\n");
  ' "$state_file" "$@"
}
