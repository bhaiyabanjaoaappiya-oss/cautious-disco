#!/bin/bash
#
# setup-macos-tailscale-novnc.sh
# For use on a self-hosted macOS runner (your Mac).
#
set -euo pipefail
IFS=$'\n\t'

USERNAME=$(whoami)
VNC_PASSWORD=${VNC_PASSWORD:-"runner"}
TAILSCALE_AUTHKEY=${TAILSCALE_AUTHKEY:-""}
TAILSCALE_HOSTNAME=${TAILSCALE_HOSTNAME:-"macos-novnc-$(date +%s)"}
NOVNC_PORT=${NOVNC_PORT:-6080}
NOVNC_ROOT="/opt/noVNC"

echo "=========================================="
echo "  macOS + Tailscale + noVNC Setup Script  "
echo "=========================================="
echo "USER: $USERNAME"
echo "VNC PASSWORD: $VNC_PASSWORD"
echo "TAILSCALE HOSTNAME: $TAILSCALE_HOSTNAME"
echo

# 1) Install Tailscale .pkg
echo ">>> Installing Tailscale .pkg..."
PKG_URL="https://pkgs.tailscale.com/stable/Tailscale-latest-macos.pkg"
PKG_PATH="/tmp/Tailscale-latest-macos.pkg"
curl -fsSL "$PKG_URL" -o "$PKG_PATH"
sudo installer -pkg "$PKG_PATH" -target /

sleep 2

# 2) Locate tailscale binary
echo ">>> Locating tailscale binary..."
TAILSCALE_BIN="$(command -v tailscale 2>/dev/null || true)"
if [ -z "$TAILSCALE_BIN" ]; then
  CANDIDATES=(/usr/local/bin/tailscale /opt/homebrew/bin/tailscale /usr/bin/tailscale /opt/tailscale/tailscale /Applications/Tailscale.app/Contents/MacOS/tailscale)
  for p in "${CANDIDATES[@]}"; do
    if [ -x "$p" ] 2>/dev/null; then
      TAILSCALE_BIN="$p"
      break
    fi
  done
fi
if [ -z "$TAILSCALE_BIN" ]; then
  FOUND=$(sudo find /usr/local /opt /Applications -maxdepth 3 -type f -name 'tailscale' 2>/dev/null | head -n1 || true)
  if [ -n "$FOUND" ]; then TAILSCALE_BIN="$FOUND"; fi
fi

if [ -n "$TAILSCALE_BIN" ]; then
  echo "Found tailscale at: ${TAILSCALE_BIN}"
else
  echo "⚠️ Could not find tailscale binary automatically."
fi

# 3) Try to start tailscaled (launchctl) — may require root and may fail on hosted runners
echo ">>> Attempting to bootstrap tailscaled via launchctl..."
sudo launchctl bootstrap system /Library/LaunchDaemons/com.tailscale.tailscaled.plist 2>/dev/null || true
sleep 2

# 4) Run tailscale up if authkey present
if [ -n "${TAILSCALE_BIN:-}" ] && [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
  echo ">>> Running: sudo ${TAILSCALE_BIN} up --authkey <redacted> --hostname ${TAILSCALE_HOSTNAME}"
  sudo "${TAILSCALE_BIN}" up --authkey "${TAILSCALE_AUTHKEY}" --hostname "${TAILSCALE_HOSTNAME}" --ssh || {
    echo "⚠️ tailscale up returned non-zero. Continuing anyway."
  }
else
  if [ -z "${TAILSCALE_AUTHKEY:-}" ]; then
    echo "⚠️ TAILSCALE_AUTHKEY not provided; tailscale will not be connected automatically."
  fi
fi

# 5) Enable macOS Screen Sharing (requires sudo)
echo ">>> Enabling macOS Screen Sharing / Remote Management..."
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -activate -configure -access -on -restart -agent -privs -all

echo ">>> Setting VNC password..."
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -configure -clientopts -setvnclegacy -vnclegacy yes -setvncpw -vncpw "${VNC_PASSWORD}"

# 6) Install noVNC + websockify (non-root installs via Homebrew/pipx)
echo ">>> Ensuring Homebrew, python3, git, pipx..."
if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew not found; installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # The brew installer may ask you to add Homebrew to PATH. Assume interactive user will follow instructions.
fi

brew install python3 git pipx || true
pipx ensurepath
export PATH="$PATH:$HOME/.local/bin"

if ! command -v websockify >/dev/null 2>&1; then
  pipx install websockify || true
fi

# 7) Install/clone noVNC under /opt (requires sudo)
echo ">>> Installing noVNC into ${NOVNC_ROOT}..."
sudo mkdir -p "${NOVNC_ROOT}"
if [ ! -d "${NOVNC_ROOT}/.git" ]; then
  sudo git clone --depth 1 https://github.com/novnc/noVNC.git "${NOVNC_ROOT}"
fi
sudo ln -sf "${NOVNC_ROOT}/vnc.html" "${NOVNC_ROOT}/index.html"
sudo chmod -R a+rX "${NOVNC_ROOT}"

# 8) Start websockify (noVNC)
echo ">>> Starting noVNC websockify on port ${NOVNC_PORT}..."
sudo pkill -f websockify || true
# run websockify as the current (non-root) user; we use the installed websockify in PATH
nohup websockify --web="${NOVNC_ROOT}" "${NOVNC_PORT}" localhost:5900 >/tmp/novnc.log 2>&1 &

# 9) Print connection info
TAILSCALE_IP="unknown"
if [ -n "${TAILSCALE_BIN:-}" ]; then
  TAILSCALE_IP=$(sudo "${TAILSCALE_BIN}" ip -4 2>/dev/null | head -n1 || true)
  if [ -z "$TAILSCALE_IP" ]; then
    TAILSCALE_IP=$(sudo "${TAILSCALE_BIN}" ip -6 2>/dev/null | head -n1 || true)
  fi
fi

echo
echo "=========================================="
echo "✅ SETUP FINISHED (best-effort)"
echo "USER: ${USERNAME}"
echo "VNC PASSWORD: ${VNC_PASSWORD}"
if [ -n "${TAILSCALE_IP}" ]; then
  echo "noVNC URL: http://${TAILSCALE_IP}:${NOVNC_PORT}/vnc.html"
  echo "VNC host: ${TAILSCALE_IP}:5900"
else
  echo "TAILSCALE IP: (not available) — run 'sudo tailscale up --authkey <key> --hostname <name>' if needed."
fi
echo "Logs: /tmp/novnc.log"
echo "=========================================="
echo "Keeping script alive (Ctrl+C to stop)."
while true; do sleep 600; done
