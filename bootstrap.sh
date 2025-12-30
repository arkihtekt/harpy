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
  install -m 0755 -d /etc/apt/keyrings

  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | \
    gpg --dearmor -o /etc/apt/keyrings/caddy.gpg

  chmod a+r /etc/apt/keyrings/caddy.gpg

  CADDY_REPO_BASE="https://dl.cloudsmith.io/public/caddy/stable/debian"
  CADDY_CODENAME="$(lsb_release -cs)"

  if ! curl -fsSL "${CADDY_REPO_BASE}/dists/${CADDY_CODENAME}/Release" >/dev/null 2>&1; then
    if curl -fsSL "${CADDY_REPO_BASE}/dists/jammy/Release" >/dev/null 2>&1; then
      CADDY_CODENAME="jammy"
    else
      echo "Error: Caddy repository unavailable (codename: ${CADDY_CODENAME})."
      if [ "$ALLOW_DEGRADED" = true ]; then
        echo "WARNING: Continuing in DEGRADED MODE. You must manually install Caddy and re-run validation."
        mark_degraded "caddy" "repo_unavailable"
        CADDY_CODENAME=""
      else
        exit 1
      fi
    fi
  fi

  if [ -n "$CADDY_CODENAME" ]; then
    rm -f /etc/apt/sources.list.d/caddy.list

    echo \
      "deb [signed-by=/etc/apt/keyrings/caddy.gpg] \
      ${CADDY_REPO_BASE} \
      ${CADDY_CODENAME} main" \
      > /etc/apt/sources.list.d/caddy.list

    apt-get update -y
    apt-get install -y --no-install-recommends caddy
  fi
else
  echo "Caddy already installed; skipping."
fi

# Enable and start (capability only; private bootstrap provides config)
if command -v caddy >/dev/null 2>&1; then
  systemctl enable --now caddy
fi

# -------------------------------------------------------------------
# Operator Convenience Wrapper
# -------------------------------------------------------------------

echo
echo "Installing Iris operator convenience wrapper..."

cat << 'EOF' > /usr/local/bin/iris
#!/usr/bin/env bash
# -------------------------------------------------------------------
# Operator Convenience Wrapper
# -------------------------------------------------------------------

set -euo pipefail

# Guard against execution inside webhook venv
if [[ -n "${VIRTUAL_ENV:-}" ]]; then
  echo "Error: Iris operator commands must not be run inside a Python virtual environment."
  echo "Deactivate the venv or run from a clean shell."
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
  echo "Error: SSH keys already exist in $SSH_DIR"
  echo "You must install on a virgin host."
  exit 1
fi

ssh-keygen -t ed25519 -f "$KEY_APP" -N "" >/dev/null
ssh-keygen -t ed25519 -f "$KEY_HOST" -N "" >/dev/null

cat > "$SSH_DIR/config" <<EOF
# -------------------------------------------------------------------
# Global Defaults
# -------------------------------------------------------------------
Host *
    ServerAliveInterval 60
    ServerAliveCountMax 3
    TCPKeepAlive yes
    AddKeysToAgent no
    IdentitiesOnly yes

# -------------------------------------------------------------------
# github-app repo
# -------------------------------------------------------------------
Host github-app
    HostName github.com
    User git
    IdentityFile $KEY_APP
    IdentitiesOnly yes

# -------------------------------------------------------------------
# github-host repo
# -------------------------------------------------------------------
Host github-host
    HostName github.com
    User git
    IdentityFile $KEY_HOST
    IdentitiesOnly yes
EOF

chmod 600 "$SSH_DIR/config"

# -------------------------------------------------------------------
# Operator Action Required
# -------------------------------------------------------------------

echo
echo "You must now add the following SSH keys to GitHub:"
echo "----------------------------------------"
cat "${KEY_APP}.pub"
echo
cat "${KEY_HOST}.pub"
echo "----------------------------------------"
echo
read -r -p "Press ENTER once keys are added."

echo
echo "Testing SSH access..."
ssh -o StrictHostKeyChecking=accept-new -T git@github-app || true
ssh -o StrictHostKeyChecking=accept-new -T git@github-host || true

# -------------------------------------------------------------------
# Clone Repositories
# -------------------------------------------------------------------

echo
echo "Cloning Iris repositories..."

APP_DIR="/opt/iris"
HOST_DIR="/opt/iris-host"

if [ -e "$APP_DIR" ] || [ -e "$HOST_DIR" ]; then
  echo "Error: /opt/iris or /opt/iris-host already exists."
  echo "You must install on a virgin host."
  exit 1
fi

git clone git@github-app:arkihtekt/iris.git "$APP_DIR"
git clone git@github-host:arkihtekt/iris-host.git "$HOST_DIR"

# -------------------------------------------------------------------
# Handoff to Private Bootstrap
# -------------------------------------------------------------------

echo
echo "Public bootstrap complete."
echo "Handing off to private host bootstrap..."
echo

cd "$HOST_DIR"

if [ ! -x "./scripts/harpy/bootstrap.sh" ]; then
  echo "Error: ./scripts/harpy/bootstrap.sh not found or not executable."
  exit 1
fi

exec ./scripts/harpy/bootstrap.sh
