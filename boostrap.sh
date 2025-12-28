#!/usr/bin/env bash
set -euo pipefail

echo "Harpy public bootstrap starting..."
echo

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

  echo \
    "deb [signed-by=/etc/apt/keyrings/caddy.gpg] \
    https://dl.cloudsmith.io/public/caddy/stable/deb \
    $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/caddy.list

  apt-get update -y
  apt-get install -y --no-install-recommends caddy
else
  echo "Caddy already installed; skipping."
fi

# Enable but do not configure
systemctl enable caddy

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
  echo "This script must run on a virgin host."
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
  echo "This script must run on a virgin host."
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

if [ ! -x "./scripts/bootstrap.sh" ]; then
  echo "Error: ./scripts/bootstrap.sh not found or not executable."
  exit 1
fi

exec ./scripts/bootstrap.sh
