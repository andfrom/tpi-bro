#!/usr/bin/env bash
# Focus-switching demo driver (charts/focusdemo, ADR-0028/0029).
#
# Task A: tiered audio transcription — near-realtime `small` chunks, each of
#         which enqueues its own `medium` refinement (always background).
# Task B: chunked synthetic compute (`crunch`).
# Both contend for a one-slot arena; the focused band's worker preempts the
# other natively, and evicted chunks re-enqueue themselves (visible as
# metrics:evicted:* on the Grafana "Focus Demo" dashboard).
#
# Usage:
#   ./run-focus-demo.sh install            # deploy the demo chart
#   ./run-focus-demo.sh audio              # synthesize + chunk demo speech
#   ./run-focus-demo.sh focus a|b          # rotate the bands (and evict)
#   ./run-focus-demo.sh scenario           # the full scripted demo
#   ./run-focus-demo.sh status             # queues/counters/pods at a glance
#   ./run-focus-demo.sh transcript         # show the tiered transcript
#   ./run-focus-demo.sh reset              # clear demo queues/metrics
#   ./run-focus-demo.sh uninstall

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHART="${SCRIPT_DIR}/../charts/focusdemo"
NS="jobqueue"
SESSION="${FOCUSDEMO_SESSION:-demo}"
AUDIO_DIR="${TMPDIR:-/tmp}/focusdemo-audio"
CHUNK_SECONDS=15

say()  { echo "==> $*"; }
info() { echo "    $*"; }
err()  { echo "ERROR: $*" >&2; exit 1; }

redis_pod() {
  kubectl get pod -n "$NS" -l app=jobqueue \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# redis-cli inside the Redis pod; use rcli_in for stdin-fed values (-x).
rcli()    { kubectl exec -n "$NS" "$(redis_pod)" -- sh -c "redis-cli --no-auth-warning -a \"\$REDIS_PASSWORD\" $*"; }
rcli_in() { kubectl exec -i -n "$NS" "$(redis_pod)" -- sh -c "redis-cli --no-auth-warning -a \"\$REDIS_PASSWORD\" -x $*"; }

cmd="${1:-}"; shift || true

case "$cmd" in

install)
  say "Installing focus demo chart…"
  helm upgrade --install focusdemo "$CHART" -n "$NS"
  info "Grafana dashboard 'Focus Demo — job queue band rotation' will appear"
  info "within ~1 min (sidecar pickup)."
  ;;

uninstall)
  helm uninstall focusdemo -n "$NS"
  kubectl delete configmap focusdemo-dashboard -n monitoring --ignore-not-found
  ;;

audio)
  command -v espeak-ng >/dev/null || err "espeak-ng not found"
  command -v ffmpeg >/dev/null || err "ffmpeg not found"
  mkdir -p "$AUDIO_DIR"
  say "Synthesizing demo speech and chunking into ${CHUNK_SECONDS}s pieces…"
  text="The quick brown fox jumps over the lazy dog. \
A focus following cluster switches its effort to whatever matters right now. \
Task one transcribes speech in near real time with a small model. \
Each finished chunk is refined later by a larger model when capacity allows. \
Task two crunches numbers in the background until focus returns to it. \
Every eviction requeues the interrupted chunk so nothing is ever lost. \
The queue is the only doorway into this cluster and that is the whole point. \
Priorities are fixed bands that rotate, so switching never runs out of room. \
This sentence exists mostly to make the audio long enough for several chunks. \
And this final sentence closes the demonstration recording."
  espeak-ng -v en -s 150 -w "$AUDIO_DIR/full_raw.wav" "$text"
  ffmpeg -y -loglevel error -i "$AUDIO_DIR/full_raw.wav" -ar 16000 -ac 1 "$AUDIO_DIR/full.wav"
  rm -f "$AUDIO_DIR"/chunk_*.wav
  ffmpeg -y -loglevel error -i "$AUDIO_DIR/full.wav" \
    -f segment -segment_time "$CHUNK_SECONDS" -ar 16000 -ac 1 "$AUDIO_DIR/chunk_%02d.wav"
  ls "$AUDIO_DIR"/chunk_*.wav | while read -r f; do
    info "$(basename "$f"): $(du -h "$f" | cut -f1)"
  done
  ;;

enqueue-chunk)
  # enqueue-chunk <idx> — internal helper (used by scenario)
  idx="$1"
  f="$AUDIO_DIR/$(printf 'chunk_%02d.wav' "$idx")"
  [[ -f "$f" ]] || err "chunk not found: $f (run: $0 audio)"
  b64=$(base64 -w0 "$f")
  printf '{"id":"%s-c%s","payload":{"session":"%s","idx":%s,"attempt":0,"language":"en","audio_b64":"%s"}}' \
    "$SESSION" "$idx" "$SESSION" "$idx" "$b64" \
    | rcli_in LPUSH jobs:transcribe.small >/dev/null
  info "enqueued audio chunk ${idx}"
  ;;

fill-crunch)
  # fill-crunch <count> <seconds-each>
  count="${1:-12}"; secs="${2:-20}"
  say "Filling jobs:crunch with ${count} chunks of ${secs}s…"
  for i in $(seq 1 "$count"); do
    rcli "LPUSH jobs:crunch '{\"id\":\"crunch-${i}\",\"payload\":{\"seconds\":${secs},\"attempt\":0}}'" >/dev/null
  done
  ;;

focus)
  which_task="${1:-}"
  case "$which_task" in
    a) foc="transcribe-small"; dem="crunch" ;;
    b) foc="crunch"; dem="transcribe-small" ;;
    *) err "usage: $0 focus a|b" ;;
  esac
  say "FOCUS → task ${which_task}  (${foc} to interactive, ${dem} to background)"
  # Band rotation: reassign the fixed bands, never invent new values.
  kubectl patch scaledjob "$foc" -n "$NS" --type=merge \
    -p '{"spec":{"jobTargetRef":{"template":{"spec":{"priorityClassName":"interactive"}}}}}' >/dev/null
  kubectl patch scaledjob "$dem" -n "$NS" --type=merge \
    -p '{"spec":{"jobTargetRef":{"template":{"spec":{"priorityClassName":"background"}}}}}' >/dev/null
  # Evict the demoted type's running worker immediately (its TERM trap
  # requeues the chunk); newly admitted pods then sort by band.
  pods=$(kubectl get pods -n "$NS" -l "app=${dem}" \
    --field-selector=status.phase=Running -o name 2>/dev/null || true)
  if [[ -n "$pods" ]]; then
    # shellcheck disable=SC2086
    kubectl delete -n "$NS" $pods --wait=false >/dev/null
    info "evicted: $pods"
  fi
  ;;

status)
  echo "── queues ─────────────────────────"
  for q in jobs:transcribe.small jobs:transcribe.medium jobs:crunch; do
    echo "  $q: $(rcli "LLEN $q" | tr -d '\r')"
  done
  echo "── counters ───────────────────────"
  for m in completed:transcribe.small completed:transcribe.medium completed:crunch \
           evicted:transcribe.small evicted:transcribe.medium evicted:crunch; do
    echo "  $m: $(rcli "GET metrics:$m" | tr -d '\r')"
  done
  echo "── workers ────────────────────────"
  kubectl get pods -n "$NS" -l 'app in (transcribe-small,transcribe-medium,crunch)' \
    -o wide 2>/dev/null | tail -n +1 || true
  ;;

transcript)
  echo "── live tier (small) ──────────────"
  rcli "HGETALL transcript:${SESSION}:small" | tr -d '\r'
  echo "── refined tier (medium) ──────────"
  rcli "HGETALL transcript:${SESSION}:medium" | tr -d '\r'
  ;;

reset)
  say "Clearing demo queues, metrics, and transcripts…"
  rcli "DEL jobs:transcribe.small jobs:transcribe.medium jobs:crunch \
        transcript:${SESSION}:small transcript:${SESSION}:medium \
        metrics:completed:transcribe.small metrics:completed:transcribe.medium \
        metrics:completed:crunch metrics:evicted:transcribe.small \
        metrics:evicted:transcribe.medium metrics:evicted:crunch" >/dev/null
  ;;

scenario)
  n_chunks=$(ls "$AUDIO_DIR"/chunk_*.wav 2>/dev/null | wc -l)
  (( n_chunks > 0 )) || err "no audio chunks — run: $0 audio"
  say "Scenario: A(focus) → B(focus) → A(focus), ${n_chunks} audio chunks + crunch backlog"
  "$0" reset
  "$0" fill-crunch 12 20
  "$0" focus a
  say "Feeding audio chunks (paced)…"
  (
    for i in $(seq 0 $((n_chunks - 1))); do
      "$0" enqueue-chunk "$i"
      sleep 10
    done
  ) &
  feeder=$!
  sleep 35
  "$0" focus b
  sleep 35
  "$0" focus a
  wait "$feeder"
  say "All chunks fed. Letting the queues drain (watch the dashboard)…"
  for _ in $(seq 1 60); do
    a=$(rcli "LLEN jobs:transcribe.small" | tr -d '\r')
    m=$(rcli "LLEN jobs:transcribe.medium" | tr -d '\r')
    [[ "$a" == "0" && "$m" == "0" ]] && break
    sleep 10
  done
  "$0" focus b   # hand the arena back so crunch drains too
  "$0" status
  echo
  "$0" transcript
  say "Scenario complete — the eviction/completion history is on the Grafana dashboard."
  ;;

*)
  err "usage: $0 {install|uninstall|audio|fill-crunch|enqueue-chunk|focus a|b|scenario|status|transcript|reset}"
  ;;
esac
