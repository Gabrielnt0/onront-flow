#!/usr/bin/env bash
# Suspend the per-workspace sandbox. Reads the lifecycle payload on stdin.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${script_dir}/lib.sh"
ensure_vercel_auth

payload="$(cat)"
resource_id="$(printf '%s' "$payload" | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8")); process.stdout.write(d.recipeResult?.userData?.resourceId ?? "")')"
[ -n "$resource_id" ] || { echo "No resource id in lifecycle payload" >&2; exit 1; }

scope="$(env_value VERCEL_SCOPE scope "")"
project="$(env_value VERCEL_PROJECT project "")"
vercel_args=()
[ -n "$scope" ] && vercel_args+=(--scope "$scope")
[ -n "$project" ] && vercel_args+=(--project "$project")

vercel sandbox stop "$resource_id" ${vercel_args[@]+"${vercel_args[@]}"} >&2
