#!/usr/bin/env bash
# Build the base snapshot for the Vercel Sandbox recipe.
# Run by hand after exporting the first-run inputs state does not have yet:
#   VERCEL_SCOPE, VERCEL_PROJECT, ORCA_VM_REPO_URL, ORCA_VM_REPO_REF, and a git token.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${script_dir}/lib.sh"

base_name="$(env_value ORCA_VM_BASE_NAME baseName orca-base)"
repo_url="$(env_value ORCA_VM_REPO_URL repoUrl "")"
repo_ref="$(env_value ORCA_VM_REPO_REF repoRef main)"
project_root="$(env_value ORCA_VM_PROJECT_ROOT projectRoot /workspace/onront-flow)"
port="$(env_value ORCA_VM_PORT port 7331)"
scope="$(env_value VERCEL_SCOPE scope "")"
project="$(env_value VERCEL_PROJECT project "")"
timeout="${ORCA_VM_TIMEOUT:-30m}"

[ -n "$repo_url" ] || { echo "repoUrl is required (set ORCA_VM_REPO_URL or state.repoUrl)" >&2; exit 64; }
[ -n "$scope" ] || { echo "scope is required (set VERCEL_SCOPE or state.scope)" >&2; exit 64; }
[ -n "$project" ] || { echo "project is required (set VERCEL_PROJECT or state.project)" >&2; exit 64; }
command -v vercel >/dev/null 2>&1 || { echo "vercel CLI is not installed" >&2; exit 69; }

vercel_args=()
[ -n "$scope" ] && vercel_args+=(--scope "$scope")
[ -n "$project" ] && vercel_args+=(--project "$project")

gh_token="${GH_TOKEN:-${GITHUB_TOKEN:-$(command -v gh >/dev/null 2>&1 && gh auth token 2>/dev/null || true)}}"
[ -n "$gh_token" ] || { echo "no git token available (GH_TOKEN, GITHUB_TOKEN, or gh auth token)" >&2; exit 77; }

cleanup_snapshot() {
  snapshot_exit=$?
  trap - EXIT
  if ! vercel sandbox remove "$1" ${vercel_args[@]+"${vercel_args[@]}"} >&2; then
    echo "Sandbox cleanup failed for $1; inspect and remove it before continuing" >&2
    snapshot_exit=1
  fi
  exit "$snapshot_exit"
}

echo "[base] provisioning build sandbox ${base_name}" >&2
trap 'cleanup_snapshot "$base_name"' EXIT
vercel sandbox create --name "$base_name" --runtime node24 --timeout "$timeout" --vcpus 4 \
  --publish-port "$port" --snapshot-expiration 30d --keep-last-snapshots 2 \
  ${vercel_args[@]+"${vercel_args[@]}"} >&2

echo "[base] installing tooling, cloning, and installing locked dependencies" >&2
vercel sandbox exec "$base_name" ${vercel_args[@]+"${vercel_args[@]}"} --timeout 25m \
  --env "GH_TOKEN=$gh_token" --env "ORCA_PROJECT_ROOT=$project_root" \
  --env "ORCA_REPO_URL=$repo_url" --env "ORCA_REPO_REF=$repo_ref" \
  -- bash -lc 'set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null
    apt-get install -y -qq git curl ca-certificates >/dev/null
    mkdir -p "$(dirname "$ORCA_PROJECT_ROOT")"
    if [ ! -d "$ORCA_PROJECT_ROOT/.git" ]; then
      git clone --branch "$ORCA_REPO_REF" "$ORCA_REPO_URL" "$ORCA_PROJECT_ROOT"
    fi
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
    npm ci --no-audit --no-fund
    node --version && npm --version && git --version
  ' >&2

echo "[base] snapshotting stopped sandbox" >&2
out="$(vercel sandbox snapshot "$base_name" --stop --expiration 30d \
  ${vercel_args[@]+"${vercel_args[@]}"} 2>&1)"
printf '%s\n' "$out" >&2
snapshot_id="$(printf '%s\n' "$out" | sed -nE 's/.*(snap_[A-Za-z0-9]+).*/\1/p' | tail -1)"
[ -n "$snapshot_id" ] || { echo "snapshot id missing in provider output" >&2; exit 1; }

merge_state \
  "baseName=${base_name}" \
  "snapshotId=${snapshot_id}" \
  "scope=${scope}" \
  "project=${project}" \
  "port=${port}" \
  "repoUrl=${repo_url}" \
  "repoRef=${repo_ref}" \
  "projectRoot=${project_root}"

trap - EXIT
cat "$state_file"
