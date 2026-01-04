#!/usr/bin/env bash
set -euo pipefail

NM_SERVICE="${NM_SERVICE:-NetworkManager}"
POWERSAVE_CONF="${POWERSAVE_CONF:-/etc/NetworkManager/conf.d/wifi-powersave.conf}"
DEBOUNCE_SECONDS="${DEBOUNCE_SECONDS:-15}"
LASTFILE="${LASTFILE:-/run/nuclear-wifi-fix.last}"

# New: remember radio state across suspend/resume
RADIO_STATE_FILE="${RADIO_STATE_FILE:-/run/nuclear-wifi-fix.radio-state}"

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

# -----------------------------
# New: Wi-Fi/Bluetooth radio state helpers
# -----------------------------

wifi_was_enabled() {
  # Prefer nmcli if available
  if have nmcli; then
    nmcli -t -f WIFI g 2>/dev/null | grep -qi '^enabled$'
    return $?
  fi
  # Fallback: rfkill
  if have rfkill; then
    # If ANY wlan is not soft-blocked, treat as enabled
    rfkill list wlan 2>/dev/null | awk '
      BEGIN{ok=1}
      /Soft blocked:/{ if ($3=="yes") {ok=0} else {ok=1} }
      END{ exit (ok?0:1) }
    '
    return $?
  fi
  return 1
}

set_wifi_radio() {
  local onoff="$1" # "on" or "off"
  if have nmcli; then
    nmcli radio wifi "$onoff" 2>/dev/null || true
    return 0
  fi
  if have rfkill; then
    if [ "$onoff" = "off" ]; then
      rfkill block wlan 2>/dev/null || true
    else
      rfkill unblock wlan 2>/dev/null || true
    fi
    return 0
  fi
  return 1
}

bt_was_enabled() {
  if have rfkill; then
    # If ANY bluetooth device is not soft-blocked, treat as enabled
    rfkill list bluetooth 2>/dev/null | awk '
      BEGIN{seen=0; enabled=0}
      /^([0-9]+:)?[[:space:]]*.*Bluetooth/{seen=1}
      /Soft blocked:/{ if ($3=="no") enabled=1 }
      END{ if (seen && enabled) exit 0; exit 1 }
    '
    return $?
  fi
  return 1
}

set_bt_radio() {
  local onoff="$1" # "on" or "off"
  if ! have rfkill; then
    return 1
  fi
  if [ "$onoff" = "off" ]; then
    rfkill block bluetooth 2>/dev/null || true
  else
    rfkill unblock bluetooth 2>/dev/null || true
  fi
}

save_radio_state() {
  local wifi_on=0 bt_on=0
  wifi_was_enabled && wifi_on=1 || true
  bt_was_enabled && bt_on=1 || true

  umask 077
  cat >"$RADIO_STATE_FILE" <<EOF
WIFI_WAS_ON=$wifi_on
BT_WAS_ON=$bt_on
EOF
  log "Saved radio state: wifi=$wifi_on bt=$bt_on -> $RADIO_STATE_FILE"
}

load_radio_state() {
  # sets WIFI_WAS_ON / BT_WAS_ON (defaults 0)
  WIFI_WAS_ON=0
  BT_WAS_ON=0
  [ -f "$RADIO_STATE_FILE" ] && . "$RADIO_STATE_FILE" 2>/dev/null || true
}

pre_suspend_radios_off() {
  save_radio_state

  # turn off in a controlled order
  if load_radio_state; [ "${WIFI_WAS_ON:-0}" = "1" ]; then
    log "Pre-suspend: turning Wi-Fi OFF"
    set_wifi_radio off || true
    sleep 1
  fi

  if load_radio_state; [ "${BT_WAS_ON:-0}" = "1" ]; then
    log "Pre-suspend: turning Bluetooth OFF"
    set_bt_radio off || true
    sleep 1
  fi
}

post_resume_restore_radios() {
  load_radio_state

  if [ "${WIFI_WAS_ON:-0}" = "1" ]; then
    log "Post-resume: restoring Wi-Fi ON"
    set_wifi_radio on || true
    sleep 1
  fi

  if [ "${BT_WAS_ON:-0}" = "1" ]; then
    log "Post-resume: restoring Bluetooth ON"
    set_bt_radio on || true
    sleep 1
  fi
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

  while true; do
    dbus-monitor --system \
      "type='signal',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'" 2>/dev/null \
    | stdbuf -oL -eL cat \
    | while IFS= read -r line; do
        # Pre-suspend: boolean true
        if echo "$line" | grep -qE 'boolean[[:space:]]+true'; then
          log "Suspend starting -> turning radios off (remembering prior state)"
          pre_suspend_radios_off
          continue
        fi

        # Post-resume: boolean false
        if echo "$line" | grep -qE 'boolean[[:space:]]+false'; then
          ensure_powersave_2

          if debounced; then
            log "Debounce: skipping resume action (ran within ${DEBOUNCE_SECONDS}s)"
            continue
          fi

          log "Resume detected -> restoring radios and resetting Wi-Fi"
          post_resume_restore_radios
          reset_wifi
        fi
      done

    log "WARNING: dbus-monitor pipeline exited; restarting watcher in 2s"
    sleep 2
  done
}

main() {
  ensure_powersave_2
  watch_resume_forever
}

main "$@"
