#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="nuclear-wifi-fix"
SCRIPT_NAME="nuclear-wifi-fix.sh"

SCRIPT_SRC="$(dirname "$(readlink -f "$0")")/$SCRIPT_NAME"
SCRIPT_DST="/usr/local/bin/$SCRIPT_NAME"
SERVICE_DST="/etc/systemd/system/$SERVICE_NAME.service"

if [[ ! -f "$SCRIPT_SRC" ]]; then
  echo "ERROR: $SCRIPT_NAME not found in current directory"
  exit 1
fi

echo "==> Installing Wi-Fi watchdog script"
sudo install -m 0755 "$SCRIPT_SRC" "$SCRIPT_DST"

echo "==> Writing systemd service: $SERVICE_NAME.service"
sudo tee "$SERVICE_DST" >/dev/null <<EOF
[Unit]
Description=Nuclear Wi-Fi Fix (reset Wi-Fi on resume, enforce powersave)
After=systemd-journald.service NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=simple
ExecStart=$SCRIPT_DST
Restart=always
RestartSec=2

# Security hardening (safe defaults)
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/etc/NetworkManager/conf.d /tmp /var/tmp /run

[Install]
WantedBy=multi-user.target
EOF

echo "==> Reloading systemd"
sudo systemctl daemon-reload

echo "==> Enabling and starting service"
sudo systemctl enable --now "$SERVICE_NAME.service"

echo
echo "✅ Nuclear Wi-Fi Fix installed and running."
echo
echo "Check status:"
echo "  systemctl status $SERVICE_NAME.service"
echo
echo "Follow logs:"
echo "  journalctl -u $SERVICE_NAME.service -f"
