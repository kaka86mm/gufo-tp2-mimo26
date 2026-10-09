import json, threading, time, urllib.request, sys
n = int(sys.argv[1]); mx = int(sys.argv[2]); prompt = sys.argv[3]
def one(i, out):
    body = json.dumps({"model":"MiMo-V2.6-Flash-RL",
        "messages":[{"role":"user","content":prompt}],
        "max_tokens":mx,"temperature":0}).encode()
    req = urllib.request.Request("http://127.0.0.1:8080/v1/chat/completions", data=body,
                                 headers={"Content-Type":"application/json"})
    try:
        r=json.loads(urllib.request.urlopen(req, timeout=900).read())
        u=r["usage"]; out[i]=(u["completion_tokens"], round(u["completion_tokens_per_second"],1))
    except Exception as e:
        out[i]=("ERR", str(e)[:40])
out={}; ts=[]
for i in range(n):
    t=threading.Thread(target=one, args=(i,out)); t.start(); ts.append(t)
t0=time.time()
for t in ts: t.join()
wall=time.time()-t0
tot=sum(o[0] for o in out.values() if isinstance(o[0],int))
print("%d-way: wall=%.1fs total=%d aggregate=%.1f t/s  per-req=%s" % (
    n, wall, tot, tot/wall, [o[1] for o in sorted(out.items())]))
