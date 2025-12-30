#HARPY_ALLOW_DEGRADED=1 \
#curl -fsSL "https://raw.githubusercontent.com/arkihtekt/harpy/main/bootstrap.sh?$(date +%s)" | bash
#
#!/usr/bin/env bash
set -euo pipefail

echo "Harpy public bootstrap starting..."
echo

# -------------------------------------------------------------------
# Flags
# -------------------------------------------------------------------

ALLOW_DEGRADED=false

while [ $# -gt 0 ]; do
  case "$1" in
    --allow-degraded)
      ALLOW_DEGRADED=true
      shift
      ;;
    *)
      echo "Error: Unknown argument: $1"
      exit 1
      ;;
  esac
done

if [ "${HARPY_ALLOW_DEGRADED:-}" = "1" ]; then
  ALLOW_DEGRADED=true
fi

HARPY_STATE_DIR="/var/lib/harpy"
HARPY_DEGRADED_FILE="${HARPY_STATE_DIR}/degraded"
HARPY_KEYS_READY_FILE="${HARPY_STATE_DIR}/keys_ready"

mark_degraded() {
  local COMPONENT="$1"
  local REASON="$2"

  mkdir -p "$HARPY_STATE_DIR"
  chmod 700 "$HARPY_STATE_DIR"

  {
    echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "component=${COMPONENT}"
    echo "reason=${REASON}"
    echo
  } >> "$HARPY_DEGRADED_FILE"

  chmod 600 "$HARPY_DEGRADED_FILE"
}

verify_github_ssh() {
  local HOST="$1"
  local STATUS=0

  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T "$HOST" >/dev/null 2>&1 || STATUS=$?

  # GitHub returns exit code 1 on successful authentication (no shell access).
  if [ "$STATUS" -eq 1 ]; then
    return 0
  fi

  return "$STATUS"
}

# -------------------------------------------------------------------
# Safety Checks
# -------------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
  echo "Error: You must run as root."
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "Error: Unsupported system (apt-get not found)."
  exit 1
fi

# -------------------------------------------------------------------
# Base System Dependencies
# -------------------------------------------------------------------

echo "Installing base system dependencies..."
echo

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  git \
  openssh-client \
  python3 \
  python3-venv \
  python3-pip \
  sqlite3 \
  gnupg \
  lsb-release

# -------------------------------------------------------------------
# Install Caddy
# -------------------------------------------------------------------

echo
echo "Installing Caddy web server..."

if ! command -v caddy >/dev/null 2>&1; then
  if apt-get install -y --no-install-recommends caddy; then
    :
  else
    echo "Error: Caddy install failed."
    if [ "$ALLOW_DEGRADED" = true ]; then
      echo "WARNING: Continuing in DEGRADED MODE. Manual intervention required."
      mark_degraded "caddy" "apt_install_failed"
    else
      exit 1
    fi
  fi
else
  echo "Caddy already installed; skipping."
fi

if command -v caddy >/dev/null 2>&1; then
  systemctl enable --now caddy
fi

# -------------------------------------------------------------------
# Operator Convenience Wrapper
# -------------------------------------------------------------------

echo
echo "Installing operator convenience wrapper..."

cat << 'EOF' > /usr/local/bin/iris
#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${VIRTUAL_ENV:-}" ]]; then
  echo "Error: Operator commands must not be run inside a Python virtual environment."
  exit 1
fi

CMD="${1:-}"

case "$CMD" in
  run)
    exec /opt/iris-host/scripts/iris-runner.sh
    ;;
  status)
    exec /opt/iris-host/scripts/iris-status.sh
    ;;
  log)
    exec /opt/iris-host/scripts/iris-log.sh "${@:2}"
    ;;
  doctor)
    exec /opt/iris-host/scripts/iris-doctor.sh
    ;;
  *)
    echo "Usage:"
    echo "  iris run"
    echo "  iris status"
    echo "  iris log [--last|--today|--judgments]"
    echo "  iris doctor"
    exit 1
    ;;
esac
EOF

chmod +x /usr/local/bin/iris

# -------------------------------------------------------------------
# SSH Key Provisioning
# -------------------------------------------------------------------

echo
echo "Provisioning SSH keys..."

SSH_DIR="/root/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

KEY_APP="$SSH_DIR/id_ed25519_app"
KEY_HOST="$SSH_DIR/id_ed25519_host"

if [ -e "$KEY_APP" ] || [ -e "$KEY_HOST" ]; then
  echo "SSH keys already present; reusing existing keys."
else
  ssh-keygen -t ed25519 -f "$KEY_APP" -N "" >/dev/null
  ssh-keygen -t ed25519 -f "$KEY_HOST" -N "" >/dev/null
fi

cat > "$SSH_DIR/config" <<EOF
Host *
    ServerAliveInterval 60
    ServerAliveCountMax 3
    TCPKeepAlive yes
    AddKeysToAgent no
    IdentitiesOnly yes

Host github-app
    HostName github.com
    User git
    IdentityFile $KEY_APP
    IdentitiesOnly yes

Host github-host
    HostName github.com
    User git
    IdentityFile $KEY_HOST
    IdentitiesOnly yes
EOF

chmod 600 "$SSH_DIR/config"

# -------------------------------------------------------------------
# Operator Action Required (Checkpoint)
# -------------------------------------------------------------------

if [ ! -f "$HARPY_KEYS_READY_FILE" ]; then
  echo
  echo "SSH keys generated. Manual authorization required."
  echo "----------------------------------------"
  echo "github-app key:"
  cat "${KEY_APP}.pub"
  echo
  echo "github-host key:"
  cat "${KEY_HOST}.pub"
  echo "----------------------------------------"
  echo
  echo "Authorize the above keys, then re-run this bootstrap."
  mkdir -p "$HARPY_STATE_DIR"
  chmod 700 "$HARPY_STATE_DIR"
  touch "$HARPY_KEYS_READY_FILE"
  chmod 600 "$HARPY_KEYS_READY_FILE"
  exit 0
fi

# -------------------------------------------------------------------
# SSH Verification
# -------------------------------------------------------------------

echo
echo "Verifying SSH access..."

if ! verify_github_ssh git@github-app; then
  echo "Error: github-app key not authorized or not functional."
  echo "Authorize the github-app key and re-run this bootstrap."
  exit 1
fi

if ! verify_github_ssh git@github-host; then
  echo "Error: github-host key not authorized or not functional."
  echo "Authorize the github-host key and re-run this bootstrap."
  exit 1
fi

# -------------------------------------------------------------------
# Clone Repositories
# -------------------------------------------------------------------

echo
echo "Cloning repositories..."

APP_DIR="/opt/iris"
HOST_DIR="/opt/iris-host"

if [ -e "$APP_DIR" ] || [ -e "$HOST_DIR" ]; then
  echo "Error: Target directories already exist."
  exit 1
fi

git clone git@github-app:arkihtekt/iris.git "$APP_DIR"
git clone git@github-host:arkihtekt/iris-host.git "$HOST_DIR"

# -------------------------------------------------------------------
# Handoff
# -------------------------------------------------------------------

echo
echo "Public bootstrap complete."
echo "Handing off to private bootstrap..."
echo

cd "$HOST_DIR"

if [ ! -x "./scripts/harpy/bootstrap.sh" ]; then
  echo "Error: Private bootstrap script missing or not executable."
  exit 1
fi

exec ./scripts/harpy/bootstrap.sh

