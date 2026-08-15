#!/bin/sh
# C-04 layer 2: BMC-resident node watchdog.
#
# Runs ON the TuringPi BMC (BusyBox/Buildroot). The BMC is the only always-on
# vantage point that survives all four nodes hanging, and the only one that
# can see the two failure signatures measured on this cluster:
#   - 2026-08-15 rknn_init wedge: ICMP alive, sshd banner dead (kernel starved)
#   - 2026-08-15 warm-reboot PCIe flake: booted "healthy" but never reachable
# Both reduce to one probe: does TCP/22 hand us an SSH banner?
#
# A node is power-cycled only when ALL of these hold:
#   - BMC reports its power as On (a deliberately-off node is never touched)
#   - the banner probe failed FAIL_THRESHOLD consecutive times
#   - its post-cycle/boot grace has expired
#   - per-node cooldown has passed AND < MAX_CYCLES_PER_DAY in 24 h
#     (a node that keeps failing stays down for a human — no boot loops)
#
# Config: /etc/bmc-watchdog.conf (sh syntax, sourced; see installer).
# Log:    /mnt/sdcard/bmc-watchdog.log (persistent; probe successes are not
#         logged — only state changes and actions).
# State:  /tmp/bmc-watchdog/ (RAM — counters reset with the BMC, safe: every
#         node starts with boot grace).
#
# Installed by scripts/install-bmc-watchdog.sh (tpi-bro repo). The BMC's
# overlay rootfs may be reset by firmware updates — re-run the installer after
# any BMC update.

CONF=/etc/bmc-watchdog.conf

# Defaults (production); overridden by $CONF.
INTERVAL=30            # seconds between probe rounds
FAIL_THRESHOLD=10      # consecutive failures before acting (10*30s = 5 min)
BOOT_GRACE=300         # seconds to leave a node alone after power-on/start
COOLDOWN=1800          # per-node minimum seconds between cycles
MAX_CYCLES_PER_DAY=3   # per-node hard cap per 24 h
NODES="1:192.168.1.11 2:192.168.1.12 3:192.168.1.13 4:192.168.1.14"
LOG=/mnt/sdcard/bmc-watchdog.log
LOG_MAX_KB=1024

# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"

STATE=/tmp/bmc-watchdog
mkdir -p "$STATE"

log() {
  echo "$(date '+%Y-%m-%dT%H:%M:%S') $*" >> "$LOG"
  # crude rotation: keep the tail when the log grows past LOG_MAX_KB
  if [ "$(du -k "$LOG" 2>/dev/null | cut -f1)" -gt "$LOG_MAX_KB" ] 2>/dev/null; then
    tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  fi
}

now() { date +%s; }

probe_ok() {
  # SSH banner grab; server talks first, so this needs no input.
  banner=$(curl -s -m 5 "telnet://$1:22" 2>/dev/null | head -c 7)
  [ "$banner" = "SSH-2.0" ]
}

power_on() {
  tpi power status 2>/dev/null | grep -q "node$1: *On"
}

cycles_in_24h() {
  f="$STATE/cycles.$1"
  [ -f "$f" ] || { echo 0; return; }
  cutoff=$(( $(now) - 86400 ))
  n=0
  while read -r ts; do
    [ "$ts" -gt "$cutoff" ] 2>/dev/null && n=$((n + 1))
  done < "$f"
  echo "$n"
}

cycle_node() {
  n=$1
  log "ACTION node$n: power-cycling (off/on via tpi)"
  tpi power off -n "$n" >/dev/null 2>&1
  sleep 8
  tpi power on -n "$n" >/dev/null 2>&1
  now >> "$STATE/cycles.$n"
  now > "$STATE/last_cycle.$n"
  touch "$STATE/cycled.$n"
}

log "START interval=${INTERVAL}s threshold=${FAIL_THRESHOLD} grace=${BOOT_GRACE}s cooldown=${COOLDOWN}s max/day=${MAX_CYCLES_PER_DAY}"

start_ts=$(now)
for pair in $NODES; do
  echo 0 > "$STATE/fails.${pair%%:*}"
done

while true; do
  for pair in $NODES; do
    n=${pair%%:*}
    ip=${pair#*:}

    # Respect boot grace (daemon start or recent cycle).
    last_cycle=$(cat "$STATE/last_cycle.$n" 2>/dev/null || echo "$start_ts")
    if [ $(( $(now) - last_cycle )) -lt "$BOOT_GRACE" ]; then
      continue
    fi

    if ! power_on "$n"; then
      # Deliberately off (or BMC query failed) — never act, reset counter.
      echo 0 > "$STATE/fails.$n"
      continue
    fi

    fails=$(cat "$STATE/fails.$n" 2>/dev/null || echo 0)
    if probe_ok "$ip"; then
      if [ -f "$STATE/cycled.$n" ]; then
        log "RECOVERED node$n: ssh banner back after power-cycle"
        rm -f "$STATE/cycled.$n"
      elif [ "$fails" -ge 1 ]; then
        log "RECOVERED node$n: ssh banner back on its own after $fails failures"
      fi
      echo 0 > "$STATE/fails.$n"
      continue
    fi

    fails=$((fails + 1))
    echo "$fails" > "$STATE/fails.$n"
    [ "$fails" -eq 1 ] && log "FAIL node$n ($ip): ssh banner probe failed (1/${FAIL_THRESHOLD})"
    [ "$fails" -lt "$FAIL_THRESHOLD" ] && continue

    # Threshold reached — check guards.
    since_cycle=$(( $(now) - $(cat "$STATE/last_cycle.$n" 2>/dev/null || echo 0) ))
    if [ "$since_cycle" -lt "$COOLDOWN" ]; then
      [ "$fails" -eq "$FAIL_THRESHOLD" ] && log "HOLD node$n: threshold reached but cooldown active (${since_cycle}s < ${COOLDOWN}s)"
      continue
    fi
    if [ "$(cycles_in_24h "$n")" -ge "$MAX_CYCLES_PER_DAY" ]; then
      [ "$fails" -eq "$FAIL_THRESHOLD" ] && log "GIVE-UP node$n: ${MAX_CYCLES_PER_DAY} cycles in 24h already — leaving it down for a human"
      continue
    fi

    log "WEDGED node$n ($ip): $fails consecutive probe failures, power reported On"
    cycle_node "$n"
    echo 0 > "$STATE/fails.$n"
  done
  sleep "$INTERVAL"
done
