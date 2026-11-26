#!/usr/bin/env bash
# Destroy the per-workspace sandbox. Reads the lifecycle payload on stdin.
# Orca may send this with instanceId but no recipeResult, so the resource is
# derived from the instance id when the payload has no resource id.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${script_dir}/lib.sh"
ensure_vercel_auth

payload="$(cat)"
resource_id="$(printf '%s' "$payload" | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8")); process.stdout.write(d.recipeResult?.userData?.resourceId ?? "")')"

scope="$(env_value VERCEL_SCOPE scope "")"
project="$(env_value VERCEL_PROJECT project "")"
vercel_args=()
[ -n "$scope" ] && vercel_args+=(--scope "$scope")
[ -n "$project" ] && vercel_args+=(--project "$project")

if [ -z "$resource_id" ]; then
  instance_id="$(printf '%s' "$payload" | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8")); process.stdout.write(d.instanceId ?? "")')"
  [ -n "$instance_id" ] || { echo "No resource id or instance id in lifecycle payload" >&2; exit 1; }
  recipe_id="${ORCA_RECIPE_ID:-vercel-sandbox}"
  recipe_id="${recipe_id//./-}"
  max_recipe_id_length=$((128 - ${#instance_id} - 6))
  [ "$max_recipe_id_length" -gt 0 ] || { echo "instance id too long to derive a resource name" >&2; exit 1; }
  resource_id="orca-${recipe_id:0:max_recipe_id_length}-${instance_id}"
  echo "[destroy] no resource id in payload; derived ${resource_id} from instance id" >&2
fi

vercel sandbox remove "$resource_id" --delete-orphan-snapshots \
  ${vercel_args[@]+"${vercel_args[@]}"} >&2
