#!/bin/bash
# restore-prod.sh — put the pinned rollback binary back on both ranks, start it
# with the production configuration, and wait until the pair is really serving.
#
# Two callers can want this at once (the supervisor's auto-restore and a manual
# deploy), so (a) take an exclusive lock and (b) only release the shared
# /tmp/mimo-no-supervise marker if this run created it. On 2026-10-09 a manual
# restore and the supervisor's restore overlapped, each pkill killed the other's
# rank, and the pair ended up down.
exec 9>/tmp/mimo-restore.lock
flock -n 9 || { echo "!! another restore is already in flight"; exit 1; }
GUARD=/tmp/mimo-no-supervise
guard_owned=0
if [ ! -e "$GUARD" ]; then touch "$GUARD"; guard_owned=1; fi
release_guard() { [ "$guard_owned" = 1 ] && rm -f "$GUARD"; return 0; }
trap release_guard EXIT
set -euo pipefail
# Repo root (this file lives in deploy/).
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PAT='gufo-.*serve.*--tp-ran''k'

RANK1=${RANK1:-matri@192.168.110.44}
BIN=${BIN:-$HOME/gufo-mimo2-bin}
KEEP=${KEEP:-$BIN.splitk}
# Liveness must anchor on the binary path: an unrelated command line that
# merely contains "gufo-...serve" would otherwise look like a live rank.
CHECK_PAT="^$BIN serve"

pkill -f "$PAT" 2>/dev/null || true
ssh -o BatchMode=yes -o ConnectTimeout=5 $RANK1 "pkill -f '$PAT'" 2>/dev/null || true
for i in $(seq 1 15); do sleep 2; pgrep -f "$PAT" >/dev/null || break; done
if pgrep -f "$PAT" >/dev/null; then
  # A stuck engine keeps its ~110 GB (rss stays low while the GPU pins memory),
  # so the next load starts starved and the kernel OOMs it; escalate to KILL as
  # mimo-stop.sh already does.
  echo "!! ranks survived TERM; escalating to KILL"
  pkill -9 -f "$PAT" 2>/dev/null || true
  ssh -o BatchMode=yes -o ConnectTimeout=5 $RANK1 "pkill -9 -f '$PAT'" 2>/dev/null || true
  sleep 3
fi
if pgrep -f "$CHECK_PAT" >/dev/null; then echo "!! rank0 still alive after KILL"; exit 1; fi
if ssh -o BatchMode=yes -o ConnectTimeout=5 $RANK1 "pgrep -f '$CHECK_PAT' >/dev/null"; then echo "!! rank1 still alive after KILL"; exit 1; fi
# Replace by atomic rename: a rank that was just SIGKILLed still maps the old
# binary for a moment, and writing into a running executable fails with ETXTBSY
# ("dest open ... Failure" on 2026-10-09 12:25) even though pgrep already sees
# no process. rename(2) is immune to that.
cp "$KEEP" "$BIN.new" && mv -f "$BIN.new" "$BIN"
scp -q "$BIN" "$RANK1:$BIN.new" && ssh -o BatchMode=yes -o ConnectTimeout=5 $RANK1 "mv -f $BIN.new $BIN"
md5_a=$(md5sum "$BIN" | cut -d' ' -f1 | cut -c1-8)
md5_b=$(ssh -o BatchMode=yes -o ConnectTimeout=5 $RANK1 "md5sum $BIN" | cut -d' ' -f1 | cut -c1-8)
echo "restored rank0=$md5_a rank1=$md5_b"
[ "$md5_a" = "$md5_b" ] || { echo "!! md5 mismatch"; exit 1; }

rm -f /tmp/mimo-rank0.log
cp "$REPO/run/start-tp2-mimo.sh" /tmp/start-deploy.sh
# 9>&- matters: without it the engine (and the start script's bash, which
# stays blocked on the rank1 ssh) inherit the flock fd, so the mutex stays held
# for the whole engine lifetime and every later restore fails with "already in
# flight" - including the supervisor's auto-restore.
SESSIONS=6 CONTEXT=204800 setsid nohup bash /tmp/start-deploy.sh \
  9>&- > /tmp/deploy-start.log 2>&1 < /dev/null &
# Readiness = rank0 health 200 AND a live rank1 engine. "event=listening" is
# not enough: it can be printed before the 6x256K KV is allocated, and rank0
# alone answers /health even with its peer gone (it exits about a minute later).
ready=0
for i in $(seq 1 120); do
  sleep 4
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 http://127.0.0.1:8080/health || true)
  if [ "$code" = "200" ]; then
    if ssh -o BatchMode=yes -o ConnectTimeout=5 $RANK1 "pgrep -f '$CHECK_PAT' >/dev/null"; then ready=1; break; fi
  fi
done
grep -a "load_completed" /tmp/mimo-rank0.log 2>/dev/null | tail -1 | cut -c1-200 || true
if [ "$ready" = "1" ]; then
  echo "== ready ($md5_a): rank0 health 200 and rank1 engine alive =="
else
  echo "!! not ready: rank0 health=$code"; tail -6 "$HOME/logs/mimo-rank0.log" 2>/dev/null || true
  exit 1
fi
