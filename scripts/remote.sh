#!/usr/bin/env bash
# Remote deploy helper (Unix / WSL / Ubuntu workstation → Ubuntu server)
# Usage: ./scripts/remote.sh <check|sync|up|down|restart|logs|ps|status|pull|ssh> [remote cmd...]

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

load_env() {
  [[ -f .env ]] || { echo "Missing .env"; exit 1; }
  set -a
  # shellcheck disable=SC1091
  source <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' .env | sed 's/\r$//')
  set +a
}

load_env
: "${DEPLOY_HOST:?Set DEPLOY_HOST in .env}"
DEPLOY_USER="${DEPLOY_USER:-ubuntu}"
DEPLOY_PATH="${DEPLOY_PATH:-/opt/zeroclaw}"
DEPLOY_SSH_PORT="${DEPLOY_SSH_PORT:-22}"

SSH_OPTS=(-p "$DEPLOY_SSH_PORT" -o StrictHostKeyChecking=accept-new)
# scp: -P is port; -p is preserve (do not reuse SSH_OPTS for scp)
SCP_OPTS=(-P "$DEPLOY_SSH_PORT" -o StrictHostKeyChecking=accept-new)
[[ -n "${DEPLOY_SSH_KEY:-}" ]] && SSH_OPTS+=(-i "$DEPLOY_SSH_KEY") && SCP_OPTS+=(-i "$DEPLOY_SSH_KEY")
TARGET="${DEPLOY_USER}@${DEPLOY_HOST}"

remote() {
  ssh "${SSH_OPTS[@]}" "$TARGET" "$@"
}

ACTION="${1:-}"
shift || true

case "$ACTION" in
  check)
    echo "Checking SSH: $TARGET:$DEPLOY_SSH_PORT → $DEPLOY_PATH"
    remote "echo ok && uname -a && docker --version && docker compose version"
    ;;
  sync)
    command -v node >/dev/null && node scripts/sync-config.js || true

    # Single source of truth shared with remote.ps1 (see scripts/deploy-manifest.txt)
    manifest="scripts/deploy-manifest.txt"
    [[ -f "$manifest" ]] || { echo "Missing sync manifest: $manifest"; exit 1; }
    files=()
    while IFS= read -r line; do
      files+=("$line")
    done < <(grep -vE '^[[:space:]]*(#|$)' "$manifest" | sed -e 's/\r$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    # Remote dirs = runtime data dir + every parent directory in the manifest
    dirs=(data/data)
    for f in "${files[@]}"; do
      [[ "$f" == */* ]] && dirs+=("${f%/*}")
    done
    mkdir_args=""
    while IFS= read -r d; do
      mkdir_args+=" '$DEPLOY_PATH/$d'"
    done < <(printf '%s\n' "${dirs[@]}" | sort -u)
    remote "mkdir -p$mkdir_args"

    for f in "${files[@]}"; do
      [[ -f "$f" ]] || continue
      echo "scp $f"
      scp "${SCP_OPTS[@]}" "$f" "$TARGET:$DEPLOY_PATH/$f"
    done

    [[ -f secrets/google/credentials.json ]] || \
      echo "No secrets/google/credentials.json yet (see docs/google-workspace.md)"

    # Drop stale gws token cache so new refresh-token scopes take effect
    remote "rm -f '$DEPLOY_PATH/secrets/google/token_cache.json'; rm -rf '$DEPLOY_PATH/secrets/google/cache'"
    echo "Synced to $TARGET:$DEPLOY_PATH"
    ;;
  up)
    bust=$(date +%s)
    remote "cd '$DEPLOY_PATH' && docker compose build --pull --build-arg TOOLS_CACHEBUST=$bust && docker compose up -d"
    ;;
  down) remote "cd '$DEPLOY_PATH' && docker compose down" ;;
  restart) remote "cd '$DEPLOY_PATH' && docker compose restart" ;;
  logs) ssh "${SSH_OPTS[@]}" -t "$TARGET" "cd '$DEPLOY_PATH' && docker compose logs -f --tail=100" ;;
  ps) remote "cd '$DEPLOY_PATH' && docker compose ps" ;;
  status) remote "cd '$DEPLOY_PATH' && docker compose exec -T zeroclaw zeroclaw status --format=exit-code && echo OK" ;;
  pull)
    bust=$(date +%s)
    remote "cd '$DEPLOY_PATH' && docker compose build --pull --build-arg TOOLS_CACHEBUST=$bust"
    ;;
  bind)
    UID_ARG="${1:-}"
    if [[ -z "$UID_ARG" && -n "${TELEGRAM_ALLOWED_USERS:-}" ]]; then
      UID_ARG="${TELEGRAM_ALLOWED_USERS%%,*}"
      UID_ARG="$(echo "$UID_ARG" | tr -d '[:space:]')"
    fi
    [[ -n "$UID_ARG" ]] || { echo "Usage: $0 bind <telegram_user_id>"; exit 1; }
    echo "Binding Telegram user $UID_ARG on server..."
    # Schema v3: bind fills external_peers; agents must include the agent alias.
    remote "cd '$DEPLOY_PATH' && docker compose exec -T zeroclaw zeroclaw channel bind-telegram $UID_ARG && docker compose exec -T zeroclaw zeroclaw config set peer_groups.telegram_default.agents '[\"main\"]' && docker compose restart zeroclaw"
    echo "Bound. Send your Telegram message again."
    ;;
  ssh)
    if [[ $# -gt 0 ]]; then
      ssh "${SSH_OPTS[@]}" -t "$TARGET" "cd '$DEPLOY_PATH' && $*"
    else
      ssh "${SSH_OPTS[@]}" -t "$TARGET" "cd '$DEPLOY_PATH' && exec \$SHELL -l"
    fi
    ;;
  *)
    echo "Usage: $0 <check|sync|up|down|restart|logs|ps|status|pull|ssh>"
    exit 1
    ;;
esac
