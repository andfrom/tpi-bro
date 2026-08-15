#!/bin/sh
# BMC-resident node watchdog (docs/SELF-HEALING.md, layers 2+4).
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
# Deep probe (layer 4): nodes flagged `ssd` in NODES are additionally
# checked via node-exporter (:9100) for the /mnt/ssd mount. This catches the
# "booted healthy but NVMe never enumerated" PCIe-flake state, which the ssh
# probe cannot see — and a cold power-cycle is exactly its fix. Deep failures
# use their own counter/threshold and a longer grace (node-exporter is a
# DaemonSet pod, slower to appear after boot than sshd), same cycle guards.
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
DEEP_THRESHOLD=10      # consecutive deep-probe failures before acting
DEEP_GRACE=600         # deep probes need DaemonSet pods up, not just sshd
COOLDOWN=1800          # per-node minimum seconds between cycles
MAX_CYCLES_PER_DAY=3   # per-node hard cap per 24 h
# node:<ip>:<expectation> — expectation `ssd` enables the deep probe
# (node-exporter must report a /mnt/ssd mount), `-` disables it.
NODES="1:192.168.1.11:ssd 2:192.168.1.12:ssd 3:192.168.1.13:ssd 4:192.168.1.14:-"
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

deep_probe_ok() {
  # node-exporter must be up AND report the expected /mnt/ssd mount.
  curl -s -m 5 "http://$1:9100/metrics" 2>/dev/null \
    | grep -q 'node_filesystem_size_bytes{.*mountpoint="/mnt/ssd"'
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

# Shared guard-check + cycle for both probe tracks. $3 is the counter value
# (guards log only when it EQUALS its threshold, so HOLD/GIVE-UP appear once).
guarded_cycle() { # node reason at_threshold
  n=$1; reason=$2; first=$3
  since_cycle=$(( $(now) - $(cat "$STATE/last_cycle.$n" 2>/dev/null || echo 0) ))
  if [ "$since_cycle" -lt "$COOLDOWN" ]; then
    [ "$first" = yes ] && log "HOLD node$n ($reason): threshold reached but cooldown active (${since_cycle}s < ${COOLDOWN}s)"
    return 1
  fi
  if [ "$(cycles_in_24h "$n")" -ge "$MAX_CYCLES_PER_DAY" ]; then
    [ "$first" = yes ] && log "GIVE-UP node$n ($reason): ${MAX_CYCLES_PER_DAY} cycles in 24h already — leaving it for a human"
    return 1
  fi
  cycle_node "$n"
  return 0
}

log "START interval=${INTERVAL}s ssh=${FAIL_THRESHOLD}x/${BOOT_GRACE}s deep=${DEEP_THRESHOLD}x/${DEEP_GRACE}s cooldown=${COOLDOWN}s max/day=${MAX_CYCLES_PER_DAY}"

start_ts=$(now)
for spec in $NODES; do
  echo 0 > "$STATE/fails.${spec%%:*}"
  echo 0 > "$STATE/dfails.${spec%%:*}"
done

while true; do
  for spec in $NODES; do
    n=${spec%%:*}
    rest=${spec#*:}
    ip=${rest%%:*}
    expect=${rest#*:}

    # Respect boot grace (daemon start or recent cycle).
    last_cycle=$(cat "$STATE/last_cycle.$n" 2>/dev/null || echo "$start_ts")
    if [ $(( $(now) - last_cycle )) -lt "$BOOT_GRACE" ]; then
      continue
    fi

    if ! power_on "$n"; then
      # Deliberately off (or BMC query failed) — never act, reset counters.
      echo 0 > "$STATE/fails.$n"
      echo 0 > "$STATE/dfails.$n"
      continue
    fi

    # ── Track 1: ssh banner (reachability) ──────────────────────────────
    fails=$(cat "$STATE/fails.$n" 2>/dev/null || echo 0)
    if probe_ok "$ip"; then
      if [ -f "$STATE/cycled.$n" ]; then
        log "RECOVERED node$n: ssh banner back after power-cycle"
        rm -f "$STATE/cycled.$n"
      elif [ "$fails" -ge 1 ]; then
        log "RECOVERED node$n: ssh banner back on its own after $fails failures"
      fi
      echo 0 > "$STATE/fails.$n"
    else
      fails=$((fails + 1))
      echo "$fails" > "$STATE/fails.$n"
      [ "$fails" -eq 1 ] && log "FAIL node$n ($ip): ssh banner probe failed (1/${FAIL_THRESHOLD})"
      if [ "$fails" -ge "$FAIL_THRESHOLD" ]; then
        at=no; [ "$fails" -eq "$FAIL_THRESHOLD" ] && at=yes
        if [ "$at" = yes ]; then
          log "WEDGED node$n ($ip): $fails consecutive ssh failures, power reported On"
        fi
        guarded_cycle "$n" ssh "$at" && echo 0 > "$STATE/fails.$n"
      fi
      continue   # unreachable — deep probe is meaningless this round
    fi

    # ── Track 2: deep probe (node-exporter must show the expected NVMe) ──
    [ "$expect" = "ssd" ] || continue
    if [ $(( $(now) - last_cycle )) -lt "$DEEP_GRACE" ]; then
      continue
    fi
    dfails=$(cat "$STATE/dfails.$n" 2>/dev/null || echo 0)
    if deep_probe_ok "$ip"; then
      [ "$dfails" -ge 1 ] && log "DEEP-RECOVERED node$n: /mnt/ssd visible again after $dfails failures"
      echo 0 > "$STATE/dfails.$n"
      continue
    fi
    dfails=$((dfails + 1))
    echo "$dfails" > "$STATE/dfails.$n"
    [ "$dfails" -eq 1 ] && log "DEEP-FAIL node$n ($ip): reachable but /mnt/ssd missing from node-exporter (1/${DEEP_THRESHOLD})"
    if [ "$dfails" -ge "$DEEP_THRESHOLD" ]; then
      at=no; [ "$dfails" -eq "$DEEP_THRESHOLD" ] && at=yes
      if [ "$at" = yes ]; then
        log "DEEP-WEDGED node$n ($ip): booted but NVMe absent (PCIe-flake signature) — cold cycle is the fix"
      fi
      guarded_cycle "$n" deep "$at" && echo 0 > "$STATE/dfails.$n"
    fi
  done
  sleep "$INTERVAL"
done
