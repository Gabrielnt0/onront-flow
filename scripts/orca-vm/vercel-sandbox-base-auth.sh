#!/usr/bin/env bash
# Build the agent-auth snapshot on top of the base snapshot.
# Starts the Codex device login inside the sandbox and waits for the user to
# approve the printed URL in a browser, then verifies and re-snapshots.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${script_dir}/lib.sh"
ensure_vercel_auth

source_snapshot_id="$(state_value snapshotId)"
[ -n "$source_snapshot_id" ] || { echo "state.snapshotId is empty; run the base snapshot first" >&2; exit 64; }

base_name="$(env_value ORCA_VM_BASE_NAME baseName orca-base)"
auth_name="${base_name}-auth"
port="$(env_value ORCA_VM_PORT port 7331)"
scope="$(env_value VERCEL_SCOPE scope "")"
project="$(env_value VERCEL_PROJECT project "")"
command -v vercel >/dev/null 2>&1 || { echo "vercel CLI is not installed" >&2; exit 69; }

vercel_args=()
[ -n "$scope" ] && vercel_args+=(--scope "$scope")
[ -n "$project" ] && vercel_args+=(--project "$project")

cleanup_snapshot() {
  snapshot_exit=$?
  trap - EXIT
  if ! vercel sandbox remove "$1" ${vercel_args[@]+"${vercel_args[@]}"} >&2; then
    echo "Sandbox cleanup failed for $1; inspect and remove it before continuing" >&2
    snapshot_exit=1
  fi
  exit "$snapshot_exit"
}

echo "[auth] booting ${auth_name} from ${source_snapshot_id}" >&2
trap 'cleanup_snapshot "$auth_name"' EXIT
vercel sandbox create --name "$auth_name" --snapshot "$source_snapshot_id" --timeout 30m \
  --publish-port "$port" ${vercel_args[@]+"${vercel_args[@]}"} >&2

echo "[auth] starting Codex device login in ${auth_name}; approve the URL printed below" >&2
if ! vercel sandbox exec "$auth_name" ${vercel_args[@]+"${vercel_args[@]}"} --timeout 15m \
  -- bash -lc 'codex login --device-auth' >&2; then
  echo "[auth] Codex device login failed or timed out; refusing to snapshot" >&2
  exit 1
fi

verdict="$(vercel sandbox exec "$auth_name" ${vercel_args[@]+"${vercel_args[@]}"} --timeout 30s \
  -- bash -lc 'if codex login status >/dev/null 2>&1; then echo ORCA_AGENT_LOGGED_IN; else echo ORCA_AGENT_LOGGED_OUT; fi')"
case "$verdict" in
  *ORCA_AGENT_LOGGED_IN*) ;;
  *) echo "agent not logged in; refusing to snapshot" >&2; exit 1 ;;
esac

echo "[auth] snapshotting authenticated sandbox" >&2
out="$(vercel sandbox snapshot "$auth_name" --stop --expiration 30d \
  ${vercel_args[@]+"${vercel_args[@]}"} 2>&1)"
printf '%s\n' "$out" >&2
new_id="$(printf '%s\n' "$out" | sed -nE 's/.*(snap_[A-Za-z0-9]+).*/\1/p' | tail -1)"
[ -n "$new_id" ] || { echo "authenticated snapshot id missing in provider output" >&2; exit 1; }

merge_state "snapshotId=${new_id}" "authSourceSnapshotId=${source_snapshot_id}"

trap - EXIT
cat "$state_file"
