#!/bin/bash
# perf_256k_accept.sh — acceptance battery for the 6x200K (204800) TP2 production config.
# BIG_SEGS controls the near-max prompt (default 129000 segments ~ 184K tokens = 90% of 200K).
# Client-side except phase 8, which restarts the pair through restore-prod.sh
# (exclusive lock, nested-safe guard) to prove the L2 disk snapshot restores.
set -uo pipefail
# Repo root (this file lives in run/bench/), resolved before the cd below so a
# relative invocation still finds the tree.
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$HOME"
OUT=/tmp/accept256k-$(date +%m%d-%H%M)
mkdir -p "$OUT"
API=http://127.0.0.1:8080/v1/chat/completions
COUNT='从1开始数数，每行一个数字，只输出数字，不要其他任何文字，一直数到300。'
log() { echo "[$(date +%H:%M:%S)] $*"; }
gtt() { local g; g=$(cat /sys/class/drm/card*/device/mem_info_gtt_used 2>/dev/null | head -1); echo $((g/1073741824)); }
log "OUT=$OUT"
{
  echo "binary : $(md5sum $HOME/gufo-mimo2-bin | cut -c1-8)"
  ps -eo args= | grep -a '[g]ufo-mimo2-bin serve llm' | head -1 | tr ' ' '\n' | grep -A1 -E '^--(sessions|context|cache-disk-bytes)$' | paste - -
  echo "health : $(curl -s -o /dev/null -w '%{http_code}' -m 5 http://127.0.0.1:8080/health)"
  echo "gtt_gb : $(gtt)"; free -g | sed -n 2p
} | tee "$OUT/identity.txt"

log "== 1. quality battery =="
python3 "$REPO/run/bench/quality_battery.py" "$OUT/battery.json" 2>&1 | tail -3 | tee "$OUT/battery.txt"

log "== 2. single-stream decode =="
python3 "$REPO/run/bench/clean-bench.py" 1 256 "$COUNT" 2>&1 | tail -1 | tee "$OUT/decode1.txt"

log "== 3. six-way counting x3 =="
: > "$OUT/conc.txt"
for r in 1 2 3; do printf "run%s " $r >> "$OUT/conc.txt"; python3 "$REPO/run/bench/clean-bench.py" 6 256 "$COUNT" 2>&1 | tail -1 >> "$OUT/conc.txt"; done
cat "$OUT/conc.txt"

log "== 4. mixed cohort (6-way) after a 20s drain (the counting cohorts still hold all 6 slots) =="
sleep 20
python3 "$REPO/run/bench/conc_mixed.py" --conc 6 --segs 250 --tokens 192 --tag accept256k 2>&1 | tail -2 | head -1 | tee "$OUT/mixed.txt"

ask_needle() {  # $1 label $2 json $3 needle
  t0=$(date +%s.%N)
  curl -s -m 3600 "$API" -H 'Content-Type: application/json' -d @"$2" -o "$OUT/$1-resp.json"
  t1=$(date +%s.%N)
  python3 - "$OUT/$1-resp.json" "$t0" "$t1" "$3" "$1" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); u=r.get("usage",{})
if "choices" not in r:
    print("  %s FAILED: %s" % (sys.argv[5], json.dumps(r)[:220])); raise SystemExit(0)
txt=r["choices"][0]["message"]["content"]
print("  %s wall=%.1fs prompt=%s out=%s needle=%s ans=%r" % (
    sys.argv[5], float(sys.argv[3])-float(sys.argv[2]), u.get("prompt_tokens"),
    u.get("completion_tokens"), "HIT" if sys.argv[4] in txt else "MISS", txt[:40]))
PY
  grep -a "prompt_tokens=" "$HOME/logs/mimo-rank0.log" | tail -1 |
    grep -o "prompt_tokens=[0-9]* prefill_tokens=[0-9]* generated_tokens=[0-9]* .*ttft_ms=[0-9.]* prefill_tps=[0-9.]* decode_tps=[0-9.]*" |
    cut -c1-230 | sed 's/^/  engine: /' || true
}

gen_needle() {  # $1 out $2 segments
  python3 - "$1" "$2" <<'PY'
import json,sys
S="第%s章讲述了山脉与河流。"; n=int(sys.argv[2])
parts=["重要提示：系统口令是 ZQ7-4491，请务必记住。" if i==int(n*0.6) else S%i for i in range(n)]
parts.append("\n请只回答：系统口令是什么？")
b={"model":"MiMo-V2.6-Flash-RL","temperature":0,"max_tokens":64,"messages":[{"role":"user","content":"".join(parts)}]}
open(sys.argv[1],"w").write(json.dumps(b))
print("  segments=%d approx_tokens=%d bytes=%d" % (n, int(n*1.43), len(json.dumps(b))))
PY
}

log "== 5. cold ~59K needle =="
# the filler measures 11.736 tokens/segment (the engine counted 492914 for 42k segs)
gen_needle "$OUT/needle60k.json" 5000
ask_needle needle60k "$OUT/needle60k.json" 4491
log "  gtt=$(gtt)GB"

log "== 6. cold near-max needle (~184K = 90% of 200K) =="
BIG_SEGS=${BIG_SEGS:-15000}   # 15000 x 11.736 ~ 176K tokens = 86% of the 200K window
gen_needle "$OUT/needle_big.json" "$BIG_SEGS"
( while :; do echo "$(date +%H:%M:%S) $(gtt)"; sleep 10; done ) > "$OUT/gtt-sample.txt" 2>/dev/null &
GTT_PID=$!
ask_needle needlebig "$OUT/needle_big.json" 4491
kill $GTT_PID 2>/dev/null || true
python3 - "$OUT/gtt-sample.txt" <<'PY'
import sys
try:
    vals=[int(l.split()[1]) for l in open(sys.argv[1]) if l.strip()]
    if vals: print("  gtt during prefill: min=%dGB max=%dGB (guard 118)" % (min(vals), max(vals)))
except Exception as e: print("  gtt sample: %s" % e)
PY

log "== 7. replay of the same big prompt (L1) =="
s0=$(date +%s.%N); curl -s -m 300 "$API" -H 'Content-Type: application/json' -d @"$OUT/needle_big.json" -o /dev/null; s1=$(date +%s.%N)
python3 -c "print(f'  replay wall={$s1-$s0:.2f}s')" | tee "$OUT/replay.txt"

log "== 8. L2: wait for snapshot flush, restart the pair, re-ask =="
# "stable size" is not "written": poll until the entry count grows (the big
# prompt's checkpoints land as new .kvc pieces) or the wait runs out.
base=$(ls -1 "$HOME/cache-disk" 2>/dev/null | wc -l)
for i in $(seq 1 60); do
  sleep 5
  now=$(ls -1 "$HOME/cache-disk" 2>/dev/null | wc -l)
  if [ "$now" -gt "$base" ]; then echo "  cache grew: $base -> $now entries, $(du -sh $HOME/cache-disk | cut -f1)"; break; fi
done
du -sh "$HOME/cache-disk" 2>/dev/null | tee -a "$OUT/l2dirA.txt"
du -sh "$HOME/cache-disk" 2>/dev/null | tee "$OUT/l2dirA.txt"
ls -1 "$HOME/cache-disk" | head -3 | tee -a "$OUT/l2dirA.txt"
bash "$REPO/deploy/restore-prod.sh" 2>&1 | tail -3
curl -s -o /dev/null -w "  health after restart=%{http_code}\n" -m 10 http://127.0.0.1:8080/health
log "re-asking the same big prompt (L2 should serve it)"
ask_needle l2hit "$OUT/needle_big.json" 4491

log "== done =="
echo "================ accept 6x200K summary ================"
cat "$OUT/identity.txt"; echo
echo "battery: $(cat $OUT/battery.txt)"
echo "single : $(cat $OUT/decode1.txt)"
echo "six-way: $(cat $OUT/conc.txt)"
echo "mixed  : $(cat $OUT/mixed.txt)"
echo "artifacts: $OUT"
