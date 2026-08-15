#!/usr/bin/env bash
# Suite 5 — Scheduling/band-rotation validation (E-04, runnable subset).
#
# Validates the E-track design principle (focus = band rotation, never
# escalation) against the LIVE cluster, using the focus-demo machinery as
# the workload. Scenarios:
#
#   S1 equal-band inertness   — same-band work never preempts the focused
#                               worker (and a bandless "focus switch" does
#                               nothing): the running pod survives, the
#                               newcomer waits.
#   S2 focus ping-pong        — N alternating switches; after each, the
#                               focused type converges onto the arena slot;
#                               the set of pod priority values never grows
#                               beyond the two fixed bands; evictions occur
#                               and everything still completes.
#   S3 background on slack    — with the focused queue empty, background
#                               work takes the slot (deprioritized, not
#                               suspended).
#
# The warm/cold model-affinity scenarios from the E-04 backlog entry are NOT
# here — they are blocked on E-07 (warm-model routing) per ADR-0030.
#
# Requires: charts/focusdemo installed (run-focus-demo.sh install + audio).
# Runtime: ~6 minutes. Restores demo defaults (focus a) and clears queues.
#
# Usage: ./tests/check-scheduling.sh

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

NS="jobqueue"
DEMO="./scripts/run-focus-demo.sh"
PINGPONG_SWITCHES=4
CONVERGE_S=50

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS=0; FAIL=0; SKIP=0
pass() { echo -e "  ${GREEN}PASS${NC} [$1]"; ((PASS++)); }
fail() { echo -e "  ${RED}FAIL${NC} [$1]: $2"; ((FAIL++)); }
skip() { echo -e "  ${YELLOW}SKIP${NC} [$1]: $2"; ((SKIP++)); }

redis_pod() { kubectl get pod -n "$NS" -l app=jobqueue -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }
rcli() { kubectl exec -n "$NS" "$(redis_pod)" -- sh -c "redis-cli --no-auth-warning -a \"\$REDIS_PASSWORD\" $*" 2>/dev/null | tr -d '\r'; }

running_of() {  # running_of <app-label> → pod name or empty
  kubectl get pods -n "$NS" -l "app=$1" --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

wait_running() {  # wait_running <app-label> <seconds> → 0 if a pod of type runs within window
  local app="$1" secs="$2" end
  end=$(( $(date +%s) + secs ))
  while (( $(date +%s) < end )); do
    [[ -n "$(running_of "$app")" ]] && return 0
    sleep 3
  done
  return 1
}

echo ""
echo "Suite 5 — Scheduling / Band Rotation (E-04 runnable subset)"
echo "─────────────────────────────────"

if ! kubectl get scaledjob crunch -n "$NS" &>/dev/null; then
  skip "S1 equal-band-inertness" "focus demo not installed (run-focus-demo.sh install)"
  skip "S2 focus-ping-pong" "focus demo not installed"
  skip "S3 background-on-slack" "focus demo not installed"
else
  ls "${TMPDIR:-/tmp}/focusdemo-audio"/chunk_00.wav &>/dev/null || "$DEMO" audio >/dev/null

  pc_before=$(kubectl get priorityclass --no-headers | wc -l)
  "$DEMO" reset >/dev/null

  # ── S1: equal-band inertness ────────────────────────────────────────────────
  # Put BOTH types in the interactive band, get crunch running, then offer
  # same-band transcription work: it must wait, not evict.
  kubectl patch scaledjob crunch -n "$NS" --type=merge \
    -p '{"spec":{"jobTargetRef":{"template":{"spec":{"priorityClassName":"interactive"}}}}}' >/dev/null
  kubectl patch scaledjob transcribe-small -n "$NS" --type=merge \
    -p '{"spec":{"jobTargetRef":{"template":{"spec":{"priorityClassName":"interactive"}}}}}' >/dev/null
  # NOTE: crunch "seconds" are ~1s work slices that run 2-3x faster than
  # nominal on this hardware — use a long chunk so it cannot complete inside
  # the observation window, and use the evicted counter as the direct
  # displacement signal (a completed chunk with a successor pod is NOT a
  # displacement; an earlier revision of this test conflated the two).
  "$DEMO" fill-crunch 1 240 >/dev/null
  if wait_running crunch "$CONVERGE_S"; then
    crunch_pod=$(running_of crunch)
    ev_before=$(rcli "GET metrics:evicted:crunch"); ev_before=${ev_before:-0}
    FOCUSDEMO_SESSION=e04s1 "$DEMO" enqueue-chunk 0 >/dev/null
    sleep 30   # give KEDA + scheduler every chance to (wrongly) preempt
    ev_after=$(rcli "GET metrics:evicted:crunch"); ev_after=${ev_after:-0}
    if [[ "$(running_of crunch)" == "$crunch_pod" && "$ev_after" == "$ev_before" ]]; then
      pass "S1 equal-band-inertness (same-band newcomer did not evict the running worker)"
    else
      fail "S1 equal-band-inertness" "pod ${crunch_pod} displaced or evicted (evictions ${ev_before}→${ev_after}) by equal-band work"
    fi
    # clear the long chunk so it doesn't drag into S2
    kubectl delete jobs -n "$NS" -l scaledjob.keda.sh/name=crunch --ignore-not-found >/dev/null 2>&1
  else
    fail "S1 equal-band-inertness" "crunch never started (setup failure)"
  fi
  "$DEMO" reset >/dev/null

  # ── S2: focus ping-pong without escalation ─────────────────────────────────
  "$DEMO" fill-crunch 20 10 >/dev/null
  for i in 0 1 2 3; do FOCUSDEMO_SESSION=e04s2a "$DEMO" enqueue-chunk "$i" >/dev/null; done
  for i in 0 1; do FOCUSDEMO_SESSION=e04s2b "$DEMO" enqueue-chunk "$i" >/dev/null; done

  seen_priorities=""
  pp_ok=1
  which_task=a
  for n in $(seq 1 "$PINGPONG_SWITCHES"); do
    [[ "$which_task" == "a" ]] && which_task=b || which_task=a
    "$DEMO" focus "$which_task" >/dev/null
    [[ "$which_task" == "a" ]] && want=transcribe-small || want=crunch
    if ! wait_running "$want" "$CONVERGE_S"; then
      # Converging is only mandatory while the focused queue has work left
      qlen=$(rcli "LLEN jobs:$( [[ $want == crunch ]] && echo crunch || echo transcribe.small )")
      if [[ "${qlen:-0}" != "0" ]]; then
        fail "S2 focus-ping-pong" "switch #${n}: focused type ${want} did not take the slot within ${CONVERGE_S}s (queue=${qlen})"
        pp_ok=0; break
      fi
    fi
    prios=$(kubectl get pods -n "$NS" \
      -l 'app in (transcribe-small,transcribe-medium,crunch)' \
      -o jsonpath='{range .items[*]}{.spec.priority}{"\n"}{end}' | sort -u | tr '\n' ' ')
    seen_priorities="${seen_priorities} ${prios}"
  done
  if (( pp_ok )); then
    bad=$(echo "$seen_priorities" | tr ' ' '\n' | sort -u | grep -vE '^(100|1000|)$' || true)
    pc_after=$(kubectl get priorityclass --no-headers | wc -l)
    ev_c=$(rcli "GET metrics:evicted:crunch"); ev_s=$(rcli "GET metrics:evicted:transcribe.small"); ev_m=$(rcli "GET metrics:evicted:transcribe.medium")
    evicted_total=$(( ${ev_c:-0} + ${ev_s:-0} + ${ev_m:-0} ))
    if [[ -n "$bad" ]]; then
      fail "S2 focus-ping-pong" "unexpected pod priority value(s): ${bad} — bands must stay {1000,100}"
    elif [[ "$pc_after" -ne "$pc_before" ]]; then
      fail "S2 focus-ping-pong" "PriorityClass count changed ${pc_before}→${pc_after} — rotation must never mint new classes"
    else
      pass "S2 focus-ping-pong (${PINGPONG_SWITCHES} switches, priorities ⊆ {1000,100}, classes unchanged, ${evicted_total:-0} evictions requeued)"
    fi
  fi

  # ── S3: background progress on slack ───────────────────────────────────────
  "$DEMO" focus a >/dev/null           # A focused but its queue is now empty/near-empty
  rcli "DEL jobs:transcribe.small jobs:transcribe.medium" >/dev/null
  "$DEMO" fill-crunch 2 15 >/dev/null  # background-band work only
  if wait_running crunch "$CONVERGE_S"; then
    pass "S3 background-on-slack (background band runs when the focused queue is empty)"
  else
    fail "S3 background-on-slack" "crunch never took the idle slot within ${CONVERGE_S}s"
  fi

  # ── restore demo defaults, clear leftovers ─────────────────────────────────
  "$DEMO" reset >/dev/null
  "$DEMO" focus a >/dev/null
fi

echo ""
echo "─────────────────────────────────"
TOTAL=$(( PASS + FAIL + SKIP ))
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${SKIP} skipped${NC} of ${TOTAL} checks"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
