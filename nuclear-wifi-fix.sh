#!/usr/bin/env bash
set -u
set -o pipefail

# Suspend/resume watcher + Wi-Fi reset on resume.
# Startup:
#   - Ensure exactly one wifi.powersave=2 in /etc/NetworkManager/conf.d/wifi-powersave.conf
#     (handles spaces around '=' and removes duplicates; does NOT overwrite whole file)
# Resume:
#   - Wi-Fi reset: NM radio toggle + iface bounce + Option C (reload active driver module) + restart NM
# Reliability:
#   - Two detectors (journal + time-gap fallback)
#   - Resume guard to prevent double reset per resume

# -------- Config (override via env) --------
NM_SERVICE="${NM_SERVICE:-NetworkManager}"
POWERSAVE_CONF="${POWERSAVE_CONF:-/etc/NetworkManager/conf.d/wifi-powersave.conf}"

DEBOUNCE_SECONDS="${DEBOUNCE_SECONDS:-15}"
GAP_THRESHOLD_SECONDS="${GAP_THRESHOLD_SECONDS:-8}"

LOCKDIR="${LOCKDIR:-/tmp/suspend-watch-wifi.lock}"
LASTFILE="${LASTFILE:-/tmp/suspend-watch-wifi.last}"
RESUME_GUARD="${RESUME_GUARD:-/tmp/suspend-resume.guard}"

log() {
  printf '%s %s\n' "$(date -Is)" "$*" >&2
}

acquire_single_instance_lock() {
  if mkdir "$LOCKDIR" 2>/dev/null; then
    trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT INT TERM
    return 0
  fi
  log "Another instance appears to be running. Exiting."
  exit 1
}

should_run_reset() {
  local now last
  now="$(date +%s)"
  last=0
  [[ -f "$LASTFILE" ]] && last="$(cat "$LASTFILE" 2>/dev/null || echo 0)"
  (( now - last < DEBOUNCE_SECONDS )) && return 1
  echo "$now" > "$LASTFILE" 2>/dev/null || true
  return 0
}

get_wifi_iface() {
  local iface=""
  if command -v nmcli >/dev/null 2>&1; then
    iface="$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')"
  fi
  if [[ -z "${iface:-}" ]]; then
    iface="$(for p in /sys/class/net/*; do
      [[ -d "$p/wireless" ]] && basename "$p" && break
    done)"
  fi
  printf '%s' "${iface:-}"
}

reload_iface_driver_module_option_c() {
  local iface="$1" modpath mod
  if [[ -n "$iface" && -e "/sys/class/net/$iface/device/driver/module" ]]; then
    modpath="$(readlink -f "/sys/class/net/$iface/device/driver/module" 2>/dev/null)"
    mod="$(basename "$modpath" 2>/dev/null || true)"
    if [[ -n "${mod:-}" ]]; then
      log "Wi-Fi Option C: reloading driver module: $mod"
      modprobe -r "$mod"
      sleep 1
      modprobe "$mod"
      sleep 1
    fi
  else
    log "Wi-Fi Option C: no module path for iface=${iface:-<none>} (skipped)"
  fi
}

ensure_wifi_powersave_2() {
  mkdir -p "$(dirname "$POWERSAVE_CONF")"

  if [[ ! -f "$POWERSAVE_CONF" ]]; then
    log "Creating $POWERSAVE_CONF with wifi.powersave=2"
    printf "[connection]\nwifi.powersave=2\n" > "$POWERSAVE_CONF"
    return 0
  fi

  local tmp tmp2
  tmp="$(mktemp)"
  tmp2="$(mktemp)"

  awk '
    BEGIN { in_conn=0; inserted=0 }

    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      if (in_conn && !inserted) {
        print "wifi.powersave=2"
        inserted=1
      }
      in_conn = ($0 ~ /^[[:space:]]*\[connection\][[:space:]]*$/) ? 1 : 0
      print $0
      next
    }

    /^[[:space:]]*wifi\.powersave[[:space:]]*=/ { next }

    { print $0 }

    END {
      if (in_conn && !inserted) {
        print "wifi.powersave=2"
      }
    }
  ' "$POWERSAVE_CONF" > "$tmp"

  if ! grep -qE '^[[:space:]]*\[connection\][[:space:]]*$' "$tmp"; then
    printf '\n[connection]\nwifi.powersave=2\n' >> "$tmp"
  fi

  awk '
    BEGIN{seen=0}
    /^[[:space:]]*wifi\.powersave[[:space:]]*=[[:space:]]*2[[:space:]]*$/ {
      if (seen) next
      seen=1
      print "wifi.powersave=2"
      next
    }
    {print}
  ' "$tmp" > "$tmp2"
  mv "$tmp2" "$tmp"

  if cmp -s "$POWERSAVE_CONF" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  log "Updating $POWERSAVE_CONF to enforce single wifi.powersave=2"
  cp --preserve=mode,ownership,timestamps "$tmp" "$POWERSAVE_CONF"
  rm -f "$tmp"
  return 0
}

startup_powersave_enforce() {
  log "Startup: ensuring wifi.powersave=2"
  set +e
  ensure_wifi_powersave_2
  local changed=$?
  if [[ $changed -eq 0 ]]; then
    log "Startup: powersave changed -> restarting $NM_SERVICE"
    systemctl restart "$NM_SERVICE"
  else
    log "Startup: powersave already correct"
  fi
  set -e
}

reset_wifi_on_resume() {
  log "Wi-Fi: reset sequence starting"
  set +e

  command -v nmcli >/dev/null 2>&1 && nmcli radio wifi off && sleep 2 && nmcli radio wifi on && sleep 2

  local iface
  iface="$(get_wifi_iface)"
  if [[ -n "${iface:-}" ]]; then
    log "Wi-Fi iface: $iface"
    ip link set "$iface" down
    sleep 1
    ip link set "$iface" up
    sleep 2
  fi

  [[ -n "${iface:-}" ]] && reload_iface_driver_module_option_c "$iface"

  systemctl restart "$NM_SERVICE"

  set -e
  log "Wi-Fi: reset complete"
}

handle_resume() {
  [[ -e "$RESUME_GUARD" ]] && return 0
  : > "$RESUME_GUARD"
  should_run_reset || return 0
  log "RESUME detected -> resetting Wi-Fi (single-run)"
  reset_wifi_on_resume
}

watch_journal_for_suspend_resume() {
  local resume_re suspend_re
  resume_re='Waking up from system sleep state|PM: suspend exit|PM: resume|Finished Suspend|systemd-sleep\[[0-9]+\]: System resumed|Resume from sleep'
  suspend_re='Suspending system|PM: suspend entry'

  journalctl -f -o cat 2>/dev/null | while IFS= read -r line; do
    if [[ "$line" =~ $suspend_re ]]; then
      rm -f "$RESUME_GUARD"
      log "journal: suspend detected (guard cleared)"
    elif [[ "$line" =~ $resume_re ]]; then
      log "journal: resume detected"
      handle_resume
    fi
  done
}

gap_detector() {
  local interval=1 last now delta
  last="$(date +%s)"
  while true; do
    sleep "$interval"
    now="$(date +%s)"
    delta=$((now - last))
    (( delta > interval + GAP_THRESHOLD_SECONDS )) && handle_resume
    last="$now"
  done
}

main() {
  set -e
  acquire_single_instance_lock
  rm -f "$RESUME_GUARD"
  startup_powersave_enforce
  log "Started suspend/resume Wi-Fi watchdog"
  watch_journal_for_suspend_resume &
  gap_detector &
  wait
}

main "$@"
