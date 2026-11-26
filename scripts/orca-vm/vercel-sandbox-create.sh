#!/usr/bin/env bash
# Create a per-workspace Vercel Sandbox and start `orca serve` inside it.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${script_dir}/lib.sh"
ensure_vercel_auth

snapshot_id="$(state_value snapshotId)"
scope="$(env_value VERCEL_SCOPE scope "")"
project="$(env_value VERCEL_PROJECT project "")"
port="$(env_value ORCA_VM_PORT port 7331)"
repo_url="$(env_value ORCA_VM_REPO_URL repoUrl "")"
repo_ref="$(env_value ORCA_VM_REPO_REF repoRef main)"
project_root="$(env_value ORCA_VM_PROJECT_ROOT projectRoot /workspace/onront-flow)"

[ -n "$snapshot_id" ] || {
  echo "state.snapshotId is missing; build the base and auth snapshots first" >&2
  exit 64
}

vercel_args=()
[ -n "$scope" ] && vercel_args+=(--scope "$scope")
[ -n "$project" ] && vercel_args+=(--project "$project")

command -v vercel >/dev/null 2>&1 || { echo "vercel CLI is not installed" >&2; exit 69; }

gh_token="$(github_token)"
[ -n "$gh_token" ] || { echo "no git token available (GH_TOKEN, GITHUB_TOKEN, or gh auth token)" >&2; exit 77; }

recipe_id="${ORCA_RECIPE_ID:-vercel-sandbox}"
recipe_id="${recipe_id//./-}"
instance_id="${ORCA_VM_INSTANCE_ID:-$(date +%s)}"
max_recipe_id_length=$((128 - ${#instance_id} - 6))
[ "$max_recipe_id_length" -gt 0 ] || {
  echo "ORCA_VM_INSTANCE_ID is too long for a Vercel sandbox name" >&2
  exit 64
}
name="orca-${recipe_id:0:max_recipe_id_length}-${instance_id}"

cleanup_on_error() {
  status=$?
  trap - EXIT
  if [ "$status" -ne 0 ]; then
    vercel sandbox remove "$name" --delete-orphan-snapshots \
      ${vercel_args[@]+"${vercel_args[@]}"} >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup_on_error EXIT

echo "[create] booting ${name} from snapshot ${snapshot_id}" >&2
create_output="$(vercel sandbox create --name "$name" --snapshot "$snapshot_id" \
  --timeout 30m --publish-port "$port" ${vercel_args[@]+"${vercel_args[@]}"} 2>&1)"
printf '%s\n' "$create_output" >&2

public_url="$(printf '%s\n' "$create_output" | sed -nE 's#.*(https://[^[:space:]]+\.vercel\.run).*#\1#p' | head -1)"
[ -n "$public_url" ] || { echo "no published URL in create output" >&2; exit 1; }
pairing_ws="${public_url/https:\/\//wss://}"

echo "[create] ensuring repo is at the desired commit" >&2
vercel sandbox exec "$name" ${vercel_args[@]+"${vercel_args[@]}"} --timeout 20m \
  --env "GH_TOKEN=$gh_token" --env "ORCA_PROJECT_ROOT=$project_root" \
  --env "ORCA_REPO_URL=$repo_url" --env "ORCA_REPO_REF=$repo_ref" \
  -- bash -lc 'set -euo pipefail
    cd "$ORCA_PROJECT_ROOT"
    export GIT_TERMINAL_PROMPT=0
    if [ -n "${GH_TOKEN:-}" ]; then
      printf "%s\n" "#!/usr/bin/env bash" "case \"\$1\" in *Username*) echo x-access-token;; *Password*) echo \"\$GH_TOKEN\";; esac" > /tmp/askpass.sh
      chmod 700 /tmp/askpass.sh
      export GIT_ASKPASS=/tmp/askpass.sh
    fi
    git fetch origin "$ORCA_REPO_REF"
    git checkout -B "$ORCA_REPO_REF" FETCH_HEAD
    rm -f /tmp/askpass.sh
    c="$(git rev-parse HEAD)"
    if [ ! -f .orca-built ] || [ "$(cat .orca-built)" != "$c" ]; then
      if [ -f package.json ]; then
        if [ -f package-lock.json ] || [ -f npm-shrinkwrap.json ]; then
          npm ci --no-audit --no-fund
        else
          echo "[create] no lockfile in ${ORCA_REPO_REF}; using npm install" >&2
          npm install --no-audit --no-fund
        fi
      else
        echo "[create] no package.json in ${ORCA_REPO_REF}; skipping npm install" >&2
      fi
      printf "%s" "$c" > .orca-built
    fi
  ' >&2

echo "[create] starting orca serve" >&2
recipe_json="$(vercel sandbox exec "$name" ${vercel_args[@]+"${vercel_args[@]}"} --timeout 60s \
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

# Pairing address is stored so resume does not have to guess the published URL.
node -e 'const p=JSON.parse(process.argv[1]); console.log(JSON.stringify({...p, schemaVersion:1, userData:{...p.userData, provider:"vercel-sandbox", resourceId:process.argv[2], snapshotId:process.argv[3], pairingAddress:process.argv[4]}}))' \
  "$recipe_json" "$name" "$snapshot_id" "$pairing_ws"

trap - EXIT
