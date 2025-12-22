#!/usr/bin/env bash
set -euo pipefail

echo "Harpy bootstrap starting..."
echo

if [ "$(id -u)" -ne 0 ]; then
  echo "Error: You must run as root."
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "Error: Unsupported system (apt-get not found)."
  exit 1
fi

echo "Installing base dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  git \
  openssh-client

SSH_DIR="/root/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

KEY_APP="$SSH_DIR/id_ed25519_app"
KEY_HOST="$SSH_DIR/id_ed25519_host"

if [ -e "$KEY_APP" ] || [ -e "$KEY_HOST" ]; then
  echo "Error: SSH keys already exist in $SSH_DIR"
  echo "You must strap to a virgin system with no prior configuration."
  exit 1
fi

echo
echo "Generating SSH keys for host..."
ssh-keygen -t ed25519 -f "$KEY_APP" -N "" >/dev/null
ssh-keygen -t ed25519 -f "$KEY_HOST" -N "" >/dev/null

cat > "$SSH_DIR/config" <<EOF
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

echo
echo "You may add the following keys to dependent repos:"
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

echo
echo "Cloning repositories..."

APP_DIR="/opt/app"
HOST_DIR="/opt/app-host"

if [ -e "$APP_DIR" ] || [ -e "$HOST_DIR" ]; then
  echo "Error: $APP_DIR or $HOST_DIR already exists."
  echo "This script is intended for brand-new hosts only."
  exit 1
fi

APP_REPO_SSH="git@github-app:arkihtekt/iris.git"
HOST_REPO_SSH="git@github-host:arkihtekt/iris-host.git"

git clone "$APP_REPO_SSH" "$APP_DIR"
git clone "$HOST_REPO_SSH" "$HOST_DIR"

echo
echo "Handing off..."
cd "$HOST_DIR"

if [ ! -x "./scripts/bootstrap.sh" ]; then
  echo "error: ./scripts/bootstrap.sh not found or not executable"
  exit 1
fi

exec ./scripts/bootstrap.sh
