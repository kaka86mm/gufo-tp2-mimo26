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
