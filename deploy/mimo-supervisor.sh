#!/bin/bash
# mimo-supervisor.sh — keep the TP2 pair serving without manual intervention:
#  * GTT runaway guard: a rank's RSS misses GTT, so the OOM killer never sees
#    the pinned pages and an engine that runs away with them takes the host down
#  * no busy-wait: a rank whose peer vanished is killed
#  * automatic restore once the peer answers again
# deploy/test scripts drop /tmp/mimo-no-supervise to keep their window.
set -u
# Repo root (this file lives in deploy/): the supervisor drives the repo's own
# restore and warm-up scripts, wherever the tree is checked out.
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PAT='gufo-.*serve.*--tp-ran[k]'
PEER=${PEER:-matri@192.168.110.44}
PEER_IP=${PEER_IP:-192.168.110.44}
# Must sit above the steady state (~106.4 GB for 6x200K) and below what the host
# survives: 112 GB was only ~2 GB of headroom and tripped during normal operation.
LIMIT_GB=${1:-118}
mkdir -p "$HOME/logs"
ln -sf "$HOME/logs/mimo-supervisor.log" /tmp/mimo-supervisor.log
LOG="$HOME/logs/mimo-supervisor.log"
log() { echo "$(date +%T) $*" >> "$LOG"; }
count_local() { pgrep -cf "$PAT" 2>/dev/null | head -1; }
while true; do
  sleep 20
  [ -e /tmp/mimo-no-supervise ] && continue
  gtt=$(cat /sys/class/drm/card*/device/mem_info_gtt_used 2>/dev/null | head -1)
  gtt_gb=$(( ${gtt:-0} / 1073741824 ))
  if [ "$gtt_gb" -gt "$LIMIT_GB" ]; then
    log "GTT ${gtt_gb}GB > ${LIMIT_GB}GB: killing both ranks"
    pkill -f "$PAT" 2>/dev/null || true
    ssh -o BatchMode=yes -o ConnectTimeout=5 $PEER "pkill -f '$PAT'" 2>/dev/null || true
    sleep 60
    continue
  fi
  local_up=$(count_local)
  local_up=${local_up:-0}
  peer_up=0
  ping -c1 -W2 "$PEER_IP" >/dev/null 2>&1 && peer_up=1
  if [ "$local_up" -gt 0 ] && [ "$peer_up" -eq 0 ]; then
    log "peer unreachable with a live rank: killing the local rank (no busy-wait)"
    pkill -f "$PAT" 2>/dev/null || true
    sleep 10
    continue
  fi
  if [ "$local_up" -eq 0 ] && [ "$peer_up" -eq 1 ]; then
    log "pair down, peer up: restoring production"
    if bash "$REPO/deploy/restore-prod.sh" >> "$LOG" 2>&1; then
      bash "$REPO/deploy/warmup.sh" >> "$LOG" 2>&1 || true
      log "restore complete"
    else
      log "restore failed; retrying in 120s"
      sleep 120
    fi
    sleep 60
  fi
done
