#!/bin/bash
# prod_full_test.sh — frozen-config (6x200K) full production test, prefill-heavy.
# Client-side except phase G (restart through restore-prod.sh). Every cold
# prompt uses a filler template that has never been used, so nothing is cached.
set -uo pipefail
# Repo root (this file lives in run/bench/), resolved before the cd below so a
# relative invocation still finds the tree.
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$HOME"
OUT=/tmp/prodfull-$(date +%m%d-%H%M); mkdir -p "$OUT"; : > "$OUT/lines.txt"
API=http://127.0.0.1:8080/v1/chat/completions
COUNT='从1开始数数，每行一个数字，只输出数字，不要其他任何文字，一直数到300。'
RANK1=matri@192.168.110.44
log() { echo "[$(date +%H:%M:%S)] $*"; }
gtt() { local g; g=$(cat /sys/class/drm/card*/device/mem_info_gtt_used 2>/dev/null | head -1); echo $((g/1048576)); }
say() { echo "$*" | tee -a "$OUT/lines.txt"; }

cat > /tmp/pf_sampler.sh <<'S'
#!/bin/bash
TAG=${1:-x}; OUT=/tmp/pf-mem-$TAG.txt; : > $OUT
for i in $(seq 1 400); do
  g=$(cat /sys/class/drm/card*/device/mem_info_gtt_used 2>/dev/null | head -1)
  echo "$(date +%H:%M:%S) gtt=$((g/1048576))M avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)M" >> $OUT
  sleep 10
done
S
scp -q /tmp/pf_sampler.sh $RANK1:/tmp/pf_sampler.sh
ssh -o BatchMode=yes $RANK1 'setsid nohup bash /tmp/pf_sampler.sh rank1 >/dev/null 2>&1 </dev/null &'
setsid nohup bash /tmp/pf_sampler.sh rank0 >/dev/null 2>&1 </dev/null &

mkbody() { # $1 out  $2 segments  $3 filler-char
python3 - "$1" "$2" "$3" <<'PY'
import json,sys
F={"g":"第%s页记载了城市与港口的发展。","h":"第%s项列举了矿物与岩石的种类。",
   "i":"第%s条说明了法律与契约的要点。","j":"第%s期观察了行星与彗星的轨迹。",
   "k":"第%s轮总结了工程与材料的方法。","l":"第%s版收录了诗歌与乐府的名篇。",
   "m":"第%s幕演出了悲欢与离合的故事。","n":"第%s章补充了地图与航线的细节。",
   "o":"第%s表汇总了温度与降水的记录。","p":"第%s图展示了山脉与盆地的剖面。",
   "q":"第%s节归纳了菌类与苔藓的特征。","r":"第%s段翻译了希腊与拉丁的文献。",
   "s":"第%s页整理了索引与附录的条目。","t":"第%s项复核了预算与决算的差额。",
   "u":"第%s条追踪了商路与驿站的距离。","v":"第%s期重印了旧报与年鉴的摘要。"}
S=F[sys.argv[3]]
n=int(sys.argv[2])
parts=[("重要提示：系统口令是 ZQ7-4491，请务必记住。" if i==int(n*0.6) else S%i) for i in range(n)]
parts.append("\n请只回答：系统口令是什么？")
open(sys.argv[1],"w").write(json.dumps({"model":"MiMo-V2.6-Flash-RL","temperature":0,"max_tokens":24,
  "messages":[{"role":"user","content":"".join(parts)}]}))
PY
}
ask() { # $1 label $2 body
  t0=$(date +%s.%N)
  curl -s -m 2400 "$API" -H 'Content-Type: application/json' -d @"$2" -o "$OUT/$1.json"
  t1=$(date +%s.%N)
  python3 - "$OUT/$1.json" "$t0" "$t1" "$1" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
if "choices" not in r:
    print("  %s FAILED %s" % (sys.argv[4], json.dumps(r)[:180])); raise SystemExit(0)
u=r.get("usage",{}); t=r["choices"][0]["message"]["content"]
print("  %-11s wall=%7.1fs prompt=%7s out=%s needle=%s cached=%s" % (
  sys.argv[4], float(sys.argv[3])-float(sys.argv[2]), u.get("prompt_tokens"),
  u.get("completion_tokens"), "HIT" if "4491" in t else "MISS",
  u.get("prompt_tokens_details",{}).get("cached_tokens")))
PY
  grep -a "prompt_tokens=" "$HOME/logs/mimo-rank0.log" | tail -1 |
    grep -o "prefill_tokens=[0-9]* .*cache=[a-z]* cached_tokens=[0-9]* cache_restore_ms=[0-9.]* .*ttft_ms=[0-9.]* prefill_tps=[0-9.]* decode_tps=[0-9.]*" |
    cut -c1-190 | sed 's/^/  engine: /' | tee -a "$OUT/lines.txt" || true
}

# ---------------- A identity
log "== A identity"
{ echo "binary : $(md5sum $HOME/gufo-mimo2-bin | cut -c1-8)"
  ps -eo args= | grep -a '[s]erve llm' | head -1 | tr ' ' '\n' | grep -A1 -E '^--(sessions|context|cache-ram-bytes|cache-disk-bytes|cache-disk-staging-bytes|prefill-chunk)$' | paste - - | sed 's/^/  /'
  echo "health : $(curl -s -o /dev/null -w '%{http_code}' -m 5 http://127.0.0.1:8080/health)"
  echo "gtt    : $(gtt)M   free: $(free -m | awk '/Mem:/{print $4}')M"; } | tee "$OUT/identity.txt"

# ---------------- B battery
log "== B quality battery"
python3 "$REPO/run/bench/quality_battery.py" "$OUT/battery.json" 2>&1 | tail -2 | tee -a "$OUT/lines.txt"

# ---------------- C decode
log "== C decode: single, 6-way x2, mixed after drain"
python3 "$REPO/run/bench/clean-bench.py" 1 256 "$COUNT" 2>&1 | tail -1 | tee -a "$OUT/lines.txt"
for r in 1 2; do python3 "$REPO/run/bench/clean-bench.py" 6 256 "$COUNT" 2>&1 | tail -1 | tee -a "$OUT/lines.txt"; done
sleep 25
python3 "$REPO/run/bench/conc_mixed.py" --conc 6 --segs 250 --tokens 192 --tag prodfull 2>&1 | tail -2 | head -1 | tee -a "$OUT/lines.txt"

# ---------------- D prefill ladder (cold, virgin fillers)
log "== D cold prefill ladder"
for spec in "8k 700 g" "16k 1400 h" "32k 2700 i" "64k 5400 j" "128k 10900 k" "176k 15000 l"; do
  set -- $spec; lab=$1; segs=$2; f=$3
  mkbody "$OUT/p_$lab.json" "$segs" "$f"
  say "-- cold $lab (filler $f, $segs segs)"
  ask "cold$lab" "$OUT/p_$lab.json" | tee -a "$OUT/lines.txt"
done

# ---------------- E L1 replay at 64K
log "== E L1 replay (64K)"
ask "replay64k" "$OUT/p_64k.json" | tee -a "$OUT/lines.txt"

# ---------------- F concurrent prefill: 6 x 21K, max_tokens=1
log "== F concurrent prefill 6 x ~21K"
cat > /tmp/conc_prefill.py <<'PY'
import json,time,urllib.request,concurrent.futures as cf,sys
API="http://127.0.0.1:8080/v1/chat/completions"
F=["第%s幕演出了悲欢与离合的故事。","第%s章补充了地图与航线的细节。","第%s表汇总了温度与降水的记录。",
   "第%s图展示了山脉与盆地的剖面。","第%s节归纳了菌类与苔藓的特征。","第%s段翻译了希腊与拉丁的文献。"]
def body(k):
    n=1800; S=F[k]
    parts=[("重要提示：系统口令是 ZQ7-4491，请记住。" if i==int(n*0.5) else S%(k*100000+i)) for i in range(n)]
    parts.append("\n请只回答：系统口令是什么？")
    return json.dumps({"model":"MiMo-V2.6-Flash-RL","temperature":0,"max_tokens":1,
        "messages":[{"role":"user","content":"".join(parts)}]}).encode()
def fire(k):
    t0=time.time()
    try:
        rq=urllib.request.Request(API,data=body(k),headers={"Content-Type":"application/json"})
        with urllib.request.urlopen(rq,timeout=900) as r: d=json.load(r)
        u=d.get("usage",{}); t=(d.get("choices") or [{}])[0].get("message",{}).get("content","")
        return (k,"choices" in d,time.time()-t0,u.get("prompt_tokens",0),"4491" in t)
    except Exception as e:
        return (k,False,time.time()-t0,0,str(e)[:50])
t0=time.time()
with cf.ThreadPoolExecutor(6) as ex: res=list(ex.map(fire,range(6)))
wall=time.time()-t0
ok=sum(1 for r in res if r[1]); tot=sum(r[3] for r in res if r[1]); hit=sum(1 for r in res if r[4] is True)
print("  conc-prefill: ok=%d/6 needle=%d/6 tokens=%d wall=%.1fs aggregate=%.0f tok/s per-req_wall=%s" % (
  ok,hit,tot,wall,tot/wall if wall else 0, ",".join("%.0f"%(r[2]) for r in res)))
PY
python3 /tmp/conc_prefill.py 2>&1 | tee -a "$OUT/lines.txt"

# ---------------- G L2 disk proof at 176K
log "== G restart + L2 re-ask of the 176K prompt"
base=$(ls -1 $HOME/cache-disk 2>/dev/null | wc -l)
for i in $(seq 1 24); do sleep 5; now=$(ls -1 $HOME/cache-disk 2>/dev/null | wc -l); [ "$now" -gt "$base" ] && { say "  cache grew $base -> $now entries, $(du -sh $HOME/cache-disk | cut -f1)"; break; }; done
ls -la $HOME/cache-disk | sort -k5 -n | tail -1 | cut -c1-125 | tee -a "$OUT/lines.txt"
bash "$REPO/deploy/restore-prod.sh" 2>&1 | tail -2 | tee -a "$OUT/lines.txt"
curl -s -o /dev/null -w "  health=%{http_code}\n" -m 5 http://127.0.0.1:8080/health
ask "l2_176k" "$OUT/p_176k.json" | tee -a "$OUT/lines.txt"

# ---------------- H soak: 10 min of 6-way counting
log "== H soak (10 min, 6-way cohorts)"
g0=$(gtt); cf_ok=0; cf_n=0; best=0; worst=999
end=$(( $(date +%s) + 600 ))
while [ "$(date +%s)" -lt "$end" ]; do
  line=$(python3 "$REPO/run/bench/clean-bench.py" 6 256 "$COUNT" 2>&1 | tail -1)
  agg=$(echo "$line" | grep -o "aggregate=[0-9.]*" | cut -d= -f2)
  cf_n=$((cf_n+1)); echo "$line" | grep -q "ERR" || cf_ok=$((cf_ok+1))
  if [ -n "${agg:-}" ]; then
    awk -v a="$agg" -v b="$best" 'BEGIN{exit !(a>b)}' && best=$agg
    awk -v a="$agg" -v b="$worst" 'BEGIN{exit !(a<b)}' && worst=$agg
  fi
  sleep 2
done
say "  soak: rounds=$cf_n clean=$cf_ok aggregate min=$worst max=$best tok/s"
say "  soak memory: gtt ${g0}M -> $(gtt)M, free $(free -m | awk '/Mem:/{print $4}')M"

# ---------------- I summary
log "== summary"
grep -a "gtt=" /tmp/pf-mem-rank0.txt | awk -F'gtt=|M avail=|M' '{if($2>g) g=$2; if(a==0||$3<a) a=$3} END{print "  rank0: gtt_max="g"M avail_min="a"M"}' | tee -a "$OUT/lines.txt"
ssh -o BatchMode=yes $RANK1 'grep -a "gtt=" /tmp/pf-mem-rank1.txt | awk -F"gtt=|M avail=|M" "{if(\$2>g) g=\$2; if(a==0||\$3<a) a=\$3} END{print \"  rank1: gtt_max=\"g\"M avail_min=\"a\"M\"}"' | tee -a "$OUT/lines.txt"
echo "================ PROD FULL TEST ($OUT) ================"
cat "$OUT/identity.txt"; echo
cat "$OUT/lines.txt"
