#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="nuclear-wifi-fix"
SERVICE_UNIT="${SERVICE_NAME}.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_UNIT}"
SCRIPT_FILE="/usr/local/bin/${SERVICE_NAME}.sh"

TMP_FILES=(
  "/tmp/suspend-watch-wifi.lock"
  "/tmp/suspend-watch-wifi.last"
  "/tmp/suspend-resume.guard"
)

echo "==> Checking service state"
ACTIVE="$(systemctl is-active "$SERVICE_UNIT" 2>/dev/null || true)"
ENABLED="$(systemctl is-enabled "$SERVICE_UNIT" 2>/dev/null || true)"
echo "    active:  ${ACTIVE}"
echo "    enabled: ${ENABLED}"

echo "==> Stopping service (if running)"
sudo systemctl stop "$SERVICE_UNIT" 2>/dev/null || true

echo "==> Disabling service (if enabled)"
sudo systemctl disable "$SERVICE_UNIT" 2>/dev/null || true

# Some systems create symlinks under multi-user.target.wants; disable handles that.

echo "==> Removing service file (if present)"
sudo rm -f "$SERVICE_FILE" 2>/dev/null || true

echo "==> Reloading systemd"
sudo systemctl daemon-reload
sudo systemctl reset-failed "$SERVICE_UNIT" 2>/dev/null || true

echo "==> Removing installed script (if present)"
sudo rm -f "$SCRIPT_FILE" 2>/dev/null || true

echo "==> Cleaning temporary state files"
for f in "${TMP_FILES[@]}"; do
  sudo rm -f "$f" 2>/dev/null || true
done

if [[ "${REMOVE_POWERSAVE_CONF:-0}" == "1" ]]; then
  POWERSAVE_CONF="/etc/NetworkManager/conf.d/wifi-powersave.conf"
  echo "==> Removing $POWERSAVE_CONF (requested)"
  sudo rm -f "$POWERSAVE_CONF" 2>/dev/null || true
  echo "==> Restarting NetworkManager"
  sudo systemctl restart NetworkManager 2>/dev/null || true
fi

echo
echo "✅ Uninstall complete."
echo "   (If the unit was running, it has been stopped.)"
