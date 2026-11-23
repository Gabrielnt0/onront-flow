#!/usr/bin/env bash
# Resume the per-workspace sandbox and re-emit fresh recipe JSON.
# Pairing may change on resume, so the fresh object is required on stdout.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${script_dir}/lib.sh"

payload="$(cat)"
resource_id="$(printf '%s' "$payload" | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8")); process.stdout.write(d.recipeResult?.userData?.resourceId ?? "")')"
[ -n "$resource_id" ] || { echo "No resource id in lifecycle payload" >&2; exit 1; }

scope="$(env_value VERCEL_SCOPE scope "")"
project="$(env_value VERCEL_PROJECT project "")"
port="$(env_value ORCA_VM_PORT port 7331)"
project_root="$(env_value ORCA_VM_PROJECT_ROOT projectRoot /workspace/onront-flow)"
vercel_args=()
[ -n "$scope" ] && vercel_args+=(--scope "$scope")
[ -n "$project" ] && vercel_args+=(--project "$project")

# The Sandbox CLI has no `start` subcommand: a persistent sandbox is resumed by
# running `sandbox exec` against its name. The published URL was captured in
# userData at create time; fall back to the live config for older result objects.
pairing_ws="$(printf '%s' "$payload" | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8")); process.stdout.write(d.recipeResult?.userData?.pairingAddress ?? "")')"

if [ -z "$pairing_ws" ]; then
  config_output="$(vercel sandbox config list "$resource_id" ${vercel_args[@]+"${vercel_args[@]}"} 2>&1 || true)"
  printf '%s\n' "$config_output" >&2
  public_url="$(printf '%s\n' "$config_output" | sed -nE 's#.*(https://[^[:space:]]+\.vercel\.run).*#\1#p' | head -1)"
  [ -n "$public_url" ] || { echo "no published URL for ${resource_id}; add pairingAddress to recipeResult.userData" >&2; exit 1; }
  pairing_ws="${public_url/https:\/\//wss://}"
fi

echo "[resume] resuming ${resource_id} via sandbox exec" >&2
recipe_json="$(vercel sandbox exec "$resource_id" ${vercel_args[@]+"${vercel_args[@]}"} --timeout 60s \
  --env "ORCA_PORT=$port" --env "ORCA_PROJECT_ROOT=$project_root" --env "ORCA_PAIRING_ADDRESS=$pairing_ws" \
  -- bash -lc 'set -euo pipefail
    cd "$ORCA_PROJECT_ROOT"
    if command -v orca >/dev/null 2>&1; then orca_bin="orca"
    elif [ -x node_modules/.bin/orca ]; then orca_bin="node_modules/.bin/orca"
    else echo "orca CLI not found in the environment; install it in the base snapshot" >&2; exit 69; fi
    rm -f /tmp/orca-recipe.json /tmp/orca-serve.log
    nohup "$orca_bin" serve --port "$ORCA_PORT" --project-root "$ORCA_PROJECT_ROOT" \
      --pairing-address "$ORCA_PAIRING_ADDRESS" --recipe-json \
      >/tmp/orca-recipe.json 2>/tmp/orca-serve.log </dev/null &
    pid=$!
    for _ in $(seq 1 80); do
      node -e "JSON.parse(require(\"node:fs\").readFileSync(\"/tmp/orca-recipe.json\",\"utf8\"))" >/dev/null 2>&1 && { cat /tmp/orca-recipe.json; exit 0; }
      kill -0 "$pid" 2>/dev/null || { cat /tmp/orca-serve.log >&2; exit 1; }
      sleep 0.25
    done
    cat /tmp/orca-serve.log >&2
    echo "serve recipe JSON timed out" >&2
    exit 1
  ')"

node -e 'const p=JSON.parse(process.argv[1]); console.log(JSON.stringify({...p, schemaVersion:1, userData:{...p.userData, provider:"vercel-sandbox", resourceId:process.argv[2], pairingAddress:process.argv[3]}}))' \
  "$recipe_json" "$resource_id" "$pairing_ws"
