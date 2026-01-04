#!/usr/bin/env bash
set -euo pipefail

NM_SERVICE="${NM_SERVICE:-NetworkManager}"
POWERSAVE_CONF="${POWERSAVE_CONF:-/etc/NetworkManager/conf.d/wifi-powersave.conf}"
DEBOUNCE_SECONDS="${DEBOUNCE_SECONDS:-15}"
LASTFILE="${LASTFILE:-/run/nuclear-wifi-fix.last}"

log() { printf '%s %s\n' "$(date -Is)" "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

ensure_powersave_2() {
  local dir tmp
  dir="$(dirname "$POWERSAVE_CONF")"
  mkdir -p "$dir"
  tmp="$(mktemp)"
  touch "$POWERSAVE_CONF"

  awk '
    BEGIN { IGNORECASE=1 }
    {
      line=$0
      gsub(/[[:space:]]*/, "", line)
      if (tolower(line) ~ /^wifi\.powersave=/) next
      print $0
    }
  ' "$POWERSAVE_CONF" > "$tmp"

  printf '%s\n' "wifi.powersave=2" >> "$tmp"

  if ! cmp -s "$tmp" "$POWERSAVE_CONF"; then
    install -m 0644 "$tmp" "$POWERSAVE_CONF"
    log "Set wifi.powersave=2 in $POWERSAVE_CONF"
  fi

  rm -f "$tmp"
}

get_wifi_iface() {
  if have nmcli; then
    nmcli -t -f DEVICE,TYPE,STATE dev 2>/dev/null \
      | awk -F: '$2=="wifi" && ($3=="connected" || $3=="disconnected" || $3=="connecting"){print $1; exit}'
    return 0
  fi

  for d in /sys/class/net/*; do
    [ -d "$d/wireless" ] && basename "$d" && return 0
  done
  return 1
}

get_wifi_driver_module() {
  local iface drv modlink
  iface="$(get_wifi_iface || true)"
  [ -z "${iface:-}" ] && return 1

  drv="$(readlink -f "/sys/class/net/$iface/device/driver" 2>/dev/null || true)"
  [ -z "${drv:-}" ] && return 1

  modlink="$(readlink -f "$drv/module" 2>/dev/null || true)"
  [ -z "${modlink:-}" ] && return 1

  basename "$modlink"
}

debounced() {
  local now last
  now="$(date +%s)"
  last=0
  [ -f "$LASTFILE" ] && last="$(cat "$LASTFILE" 2>/dev/null || echo 0)"

  if [ $((now - last)) -lt "$DEBOUNCE_SECONDS" ]; then
    return 0
  fi

  echo "$now" > "$LASTFILE"
  return 1
}

reset_wifi() {
  log "Wi-Fi: reset sequence starting"
  set +e

  if have nmcli; then
    nmcli radio wifi off; sleep 2
    nmcli radio wifi on;  sleep 2
  fi

  local iface
  iface="$(get_wifi_iface || true)"
  if [ -n "${iface:-}" ] && have ip; then
    log "Wi-Fi iface: $iface"
    ip link set "$iface" down; sleep 1
    ip link set "$iface" up;   sleep 2
  fi

  local mod
  mod="$(get_wifi_driver_module || true)"
  if [ -n "${mod:-}" ] && have modprobe; then
    log "Wi-Fi module: $mod (reload)"
    modprobe -r "$mod"; sleep 2
    modprobe "$mod";    sleep 2
  fi

  if have systemctl; then
    systemctl restart "$NM_SERVICE"; sleep 2
  fi

  set -e
  log "Wi-Fi: reset complete"
}

watch_resume_forever() {
  if ! have dbus-monitor; then
    log "ERROR: dbus-monitor not found (install package: dbus)."
    exit 1
  fi

  log "Watching for suspend/resume via logind PrepareForSleep..."

  # Critical fix: if dbus-monitor exits for ANY reason, restart it and keep running.
  while true; do
    # Use line-buffered output so we don't stall waiting on buffers.
    dbus-monitor --system \
      "type='signal',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'" 2>/dev/null \
    | stdbuf -oL -eL cat \
    | while IFS= read -r line; do
        if echo "$line" | grep -qE 'boolean[[:space:]]+false'; then
          ensure_powersave_2

          if debounced; then
            log "Debounce: skipping resume action (ran within ${DEBOUNCE_SECONDS}s)"
            continue
          fi

          log "Resume detected -> resetting Wi-Fi"
          reset_wifi
          # loop continues; daemon stays alive
        fi
      done

    # If we got here, the pipeline ended (dbus-monitor died or pipe broke).
    log "WARNING: dbus-monitor pipeline exited; restarting watcher in 2s"
    sleep 2
  done
}

main() {
  ensure_powersave_2
  watch_resume_forever
}

main "$@"
