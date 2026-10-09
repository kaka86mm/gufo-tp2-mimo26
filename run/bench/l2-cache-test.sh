#!/bin/bash
# l2cache_test.sh -- test window for the opt-in disk continuation cache (L2).
#
# Question: does a snapshot survive a *restart* (L1 is process memory, so the
# only way a restart can replay fast is the disk store)?
#
#   run A: fresh cache dir, cold 6K-token prompt         -> expect cache=miss
#   restart: both ranks down and up, same flags, L1 empty
#   run B: same prompt                                    -> expect the disk
#          store to restore it (cached_tokens>0, small ttft)
#
# Holds /tmp/mimo-no-supervise for the whole window (the supervisor restarts
# the pair when the peer answers again). Production is restored by
# deploy/restore-prod.sh at the end, without the cache flag.
set -uo pipefail
cd "$HOME"
GUARD=/tmp/mimo-no-supervise
exec 9>/tmp/mimo-restore.lock
flock -n 9 || { echo "!! another restore is already in flight"; exit 1; }
guard_owned=0
if [ ! -e "$GUARD" ]; then touch "$GUARD"; guard_owned=1; fi
trap '[ "$guard_owned" = 1 ] && rm -f "$GUARD"; echo "[guard released]"' EXIT

OUT=/tmp/l2test-$(date +%m%d-%H%M)
mkdir -p "$OUT"
CACHE_DIR=${CACHE_DIR:-$HOME/cache-disk-l2}
CACHE_BYTES=${CACHE_BYTES:-8589934592}
BIN=$HOME/gufo-mimo2-bin
RANK1=matri@192.168.110.44
# TP control-plane shared secret: both ranks must pass the same value
# (change-me-shared-secret is a placeholder — see run/env.sh).
TOKEN=${TOKEN:-change-me-shared-secret}
LOG0=$HOME/logs/mimo-rank0.log
LOG1=$HOME/logs/mimo-rank1.log
API=http://127.0.0.1:8080/v1/chat/completions
log() { echo "[$(date +%H:%M:%S)] $*"; }

log "preflight: does $BIN know --cache-disk?"
if ! "$BIN" serve llm --help 2>&1 | grep -q "cache-disk"; then
  echo "!! binary has no --cache-disk; aborting"; exit 1
fi
echo "  yes: $("$BIN" serve llm --help 2>&1 | grep -A1 -- '--cache-disk ' | tr -s ' \n' ' ')"

stop_all() {
  pkill -f 'gufo-.*serve.*--tp-ran[k]' 2>/dev/null || true
  ssh -o BatchMode=yes $RANK1 "pkill -f 'gufo-.*serve.*--tp-ran[k]'" 2>/dev/null || true
  for i in $(seq 1 20); do sleep 2; pgrep -f 'gufo-.*serve.*--tp-ran[k]' >/dev/null || break; done
}

start_pair() {  # $1 = extra flags (may be empty)
  local extra="$1"
  mkdir -p "$CACHE_DIR"; ssh -o BatchMode=yes $RANK1 "mkdir -p $CACHE_DIR"
  rm -f "$LOG0"
  setsid nohup env GUFO_NO_GRAPH=1 GUFO_MIMO_DENSE_SC=/home/matri/models/mimo26-flash-rl/dense-full-q4_0.gguf \
    GPU_MAX_HW_QUEUES=1 GUFO_AR_F16=1 HIP_VISIBLE_DEVICES=0 \
    LD_LIBRARY_PATH=/opt/rocm-7.2.4/lib:/home/matri/gufo-libs \
    $BIN serve llm \
    --model /home/matri/models/mimo26-flash-rl/MiMo-V2.6-Flash-RL-MXFP4-00001-of-00002.gguf \
    --speculative mtp --mtp-model /home/matri/models/mimo26-flash-rl/mtp-MiMo-V2.6-Flash-RL-Q8_0.gguf \
    --tp-world-size 2 --tp-rank 0 --tp-bootstrap-port 18525 --tp-control-port 18526 \
    --tp-control-token $TOKEN --tp-rdma-device usb4_rdma0 \
    --host 0.0.0.0 --port 8080 --max-pending-per-client 16 --prefill-chunk 64 \
    --sessions 8 --context 98304 $extra 9>&- > "$LOG0" 2>&1 < /dev/null &
  for i in $(seq 1 10); do sleep 1; ss -tln | grep -q 18525 && break; done
  ssh -o BatchMode=yes $RANK1 "sg render -c 'setsid nohup env GUFO_NO_GRAPH=1 GUFO_MIMO_DENSE_SC=/home/matri/models/mimo26-flash-rl/dense-full-q4_0.gguf GPU_MAX_HW_QUEUES=1 GUFO_AR_F16=1 HIP_VISIBLE_DEVICES=0 LD_LIBRARY_PATH=/opt/rocm-7.2.4/lib:/home/matri/gufo-libs \
    $BIN serve llm --model /home/matri/models/mimo26-flash-rl/MiMo-V2.6-Flash-RL-MXFP4-00001-of-00002.gguf \
    --speculative mtp --mtp-model /home/matri/models/mimo26-flash-rl/mtp-MiMo-V2.6-Flash-RL-Q8_0.gguf \
    --tp-world-size 2 --tp-rank 1 --tp-bootstrap-host 192.168.110.228 \
    --tp-bootstrap-port 18525 --tp-control-port 18526 --tp-control-token $TOKEN \
    --tp-rdma-device usb4_rdma0 --host 0.0.0.0 --port 8081 --max-pending-per-client 16 \
    --prefill-chunk 64 --sessions 8 --context 98304 $extra > $LOG1 2>&1 < /dev/null'"
  log "waiting for listening ..."
  for i in $(seq 1 90); do
    sleep 4
    curl -s -o /dev/null -m 2 http://127.0.0.1:8080/health && break
  done
  grep -a "load_completed" "$LOG0" | tail -1 | grep -o "elapsed_ms=[0-9]* .*disk_cache=[a-z]*" | cut -c1-180
  curl -s -o /dev/null -w "  health=%{http_code}\n" -m 5 http://127.0.0.1:8080/health
}

ask() {  # $1 = label
  local body=/tmp/l2test-body.json
  python3 - "$body" <<'PY'
import json, sys
SEG = "第%s篇记录了山谷与溪流的走向。"
parts = []
for i in range(560):
    if i == 280:
        parts.append("重要提示：试验口令是 L2-7742，请记住。")
    parts.append(SEG % i)
parts.append("\n请只回答：试验口令是什么？")
open(sys.argv[1], "w").write(json.dumps({
    "model": "MiMo-V2.6-Flash-RL", "temperature": 0, "max_tokens": 32,
    "messages": [{"role": "user", "content": "".join(parts)}]}))
PY
  t0=$(date +%s.%N)
  curl -s -m 600 "$API" -H 'Content-Type: application/json' -d @"$body" -o "$OUT/$1-resp.json"
  t1=$(date +%s.%N)
  python3 - "$OUT/$1-resp.json" "$t0" "$t1" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); u = r.get("usage", {})
txt = r["choices"][0]["message"]["content"]
print("  %s wall=%.2fs prompt=%s out=%s needle=%s" % (
    sys.argv[4] if len(sys.argv) > 4 else "", float(sys.argv[3]) - float(sys.argv[2]),
    u.get("prompt_tokens"), u.get("completion_tokens"),
    "HIT" if "7742" in txt else "MISS"))
PY
  grep -a "request=r" "$LOG0" | tail -1 |
    grep -o "prompt_tokens=[0-9]* generated_tokens=[0-9]*.*cache=[a-z]* cached_tokens=[0-9]* cache_restore_ms=[0-9.]*.*ttft_ms=[0-9.]*" |
    cut -c1-200 | sed 's/^/  engine: /'
}

# ---------------------------------------------------------------- run A
log "== run A: start pair with --cache-disk (fresh dir), cold prompt =="
rm -rf "$CACHE_DIR"
stop_all
start_pair "--cache-disk $CACHE_DIR --cache-disk-bytes $CACHE_BYTES"
log "cache dir after load: $(du -sh $CACHE_DIR 2>/dev/null | cut -f1) ($(ls -1 $CACHE_DIR | wc -l) entries)"
log "asking the 6K prompt (cold) ..."
ask A
log "cache dir after the request: $(du -sh $CACHE_DIR 2>/dev/null | cut -f1) ($(ls -1 $CACHE_DIR | wc -l) entries)"
ls -la "$CACHE_DIR" | head -6 | tee "$OUT/dirA.txt" >/dev/null

# ---------------------------------------------------------------- run B
log "== run B: restart both ranks (L1 empty, disk warm) =="
stop_all
start_pair "--cache-disk $CACHE_DIR --cache-disk-bytes $CACHE_BYTES"
log "asking the same prompt (disk should serve it) ..."
ask B

log "== metrics/tokens:"
curl -s -m 5 http://127.0.0.1:8080/metrics | grep -E "prompt_tokens_(cached_)?total" | sed 's/^/  /'
log "artifacts in $OUT"