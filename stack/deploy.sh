#!/usr/bin/env bash
#
# deploy.sh — run this from your laptop (Git Bash / WSL). It syncs this
# stack (including your local .env and volume.conf, if present) to the
# server and starts it.
#
# Target server is read from deploy.conf (copy deploy.conf.example to
# deploy.conf and edit it — gitignored, so it's per-machine). Override
# without editing any file via env vars or flags, e.g.:
#   REMOTE_HOST=cce-node ./deploy.sh
#   ./deploy.sh --host=cce-node --base=/opt/stacks --stack=pgvector-stack
#
# Precedence (highest wins): CLI flags > env vars > deploy.conf > built-in defaults.
#
# Requirements:
#   - rsync installed locally (see the error message below if missing)
#   - an entry for the target host in your ~/.ssh/config
#   - the remote user must be able to sudo (up.sh needs it)
#
set -euo pipefail

cd "$(dirname "$0")"

# capture any pre-set overrides from the environment before deploy.conf can clobber them
_env_host="${REMOTE_HOST-}"
_env_base="${REMOTE_BASE-}"
_env_stack="${STACK_NAME-}"

# 1. built-in defaults
REMOTE_HOST="aicoe-enterprise"
REMOTE_BASE="/compose-hub"
STACK_NAME="pgvector-stack"

# 2. deploy.conf (per-machine target)
if [[ -f deploy.conf ]]; then
  source deploy.conf
else
  echo ">> No deploy.conf found — using built-in defaults. Run: cp deploy.conf.example deploy.conf" >&2
fi

# 3. environment overrides (only if the caller explicitly set them)
[[ -n "$_env_host" ]] && REMOTE_HOST="$_env_host"
[[ -n "$_env_base" ]] && REMOTE_BASE="$_env_base"
[[ -n "$_env_stack" ]] && STACK_NAME="$_env_stack"

# 4. CLI flags (highest precedence)
for arg in "$@"; do
  case "$arg" in
    --host=*)  REMOTE_HOST="${arg#*=}" ;;
    --base=*)  REMOTE_BASE="${arg#*=}" ;;
    --stack=*) STACK_NAME="${arg#*=}" ;;
    *)
      echo "Unknown argument: $arg (expected --host=, --base=, or --stack=)" >&2
      exit 1
      ;;
  esac
done

REMOTE_DIR="${REMOTE_BASE}/${STACK_NAME}"
echo ">> Target: ${REMOTE_HOST}:${REMOTE_DIR}"

if ! command -v rsync >/dev/null 2>&1; then
  cat >&2 <<'EOF'
ERROR: rsync is not installed locally. Install it, then re-run this script:

  Git Bash / MSYS2 :  pacman -S rsync        (run inside the "Git Bash" or MSYS2 shell itself)
  Chocolatey       :  choco install rsync
  WSL              :  wsl sudo apt-get install -y rsync   (then run deploy.sh from inside WSL)
EOF
  exit 1
fi

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found. Run: cp .env.example .env   and fill in real values first." >&2
  exit 1
fi

if [[ ! -f volume.conf ]]; then
  echo ">> No volume.conf found — server will use the built-in default (CAPPED=true, CAP_SIZE=10G)." >&2
  echo "   To choose explicitly: cp volume.conf.example volume.conf   and edit it." >&2
fi

echo ">> Ensuring ${REMOTE_BASE} exists on ${REMOTE_HOST}"
ssh "$REMOTE_HOST" "
  set -e
  if [[ ! -d '${REMOTE_BASE}' ]]; then
    sudo mkdir -p '${REMOTE_BASE}'
    sudo chown \"\$(id -u):\$(id -g)\" '${REMOTE_BASE}'
  fi
  mkdir -p '${REMOTE_DIR}'
"

echo ">> Syncing files to ${REMOTE_HOST}:${REMOTE_DIR}"
rsync -avz --delete \
  --exclude '.git/' \
  --exclude 'backups/' \
  --exclude '*.sql' \
  -e ssh \
  ./ "${REMOTE_HOST}:${REMOTE_DIR}/"

echo ">> Starting stack on ${REMOTE_HOST}"
ssh "$REMOTE_HOST" "cd '${REMOTE_DIR}' && chmod +x up.sh setup-volume.sh check-mount.sh && ./up.sh"

echo ""
echo ">> Deploy complete. Tunnel to pgAdmin with:"
echo "     ssh -L 5050:localhost:5050 ${REMOTE_HOST}"
