#!/bin/bash
# mimo-stop.sh -- stop both TP2 ranks (rank0 locally, rank1 over ssh).
# Used by the systemd unit's ExecStop so `systemctl stop mimo-supervisor`
# really stops serving instead of leaving orphan ranks.
set -uo pipefail
PAT='gufo-.*serve.*--tp-ran[k]'
RANK1=${RANK1:-matri@192.168.110.44}
pkill -f "$PAT" 2>/dev/null || true
ssh -o BatchMode=yes -o ConnectTimeout=5 $RANK1 "pkill -f '$PAT'" 2>/dev/null || true
for _ in $(seq 1 15); do sleep 1; pgrep -f "$PAT" >/dev/null || break; done
pgrep -f "$PAT" >/dev/null && pkill -9 -f "$PAT" 2>/dev/null || true
echo "ranks stopped: local=$(pgrep -c -f "$PAT" 2>/dev/null || echo 0)"
