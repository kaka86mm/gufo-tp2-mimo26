#!/bin/bash
# warmup.sh — one eight-way cohort burst so GPU clocks and the batch policy
# are warm before real traffic (first cohort run measures 39-45 t/s, the
# second 65-73 on the same build).
python3 - <<'PY'
import json, threading, urllib.request
def one():
    body = json.dumps({"model":"MiMo-V2.6-Flash-RL",
        "messages":[{"role":"user","content":"Write the numbers 1 to 40 separated by commas."}],
        "max_tokens":64,"temperature":0}).encode()
    rq = urllib.request.Request("http://127.0.0.1:8080/v1/chat/completions", data=body,
                                headers={"Content-Type":"application/json"})
    try:
        urllib.request.urlopen(rq, timeout=300).read()
    except Exception:
        pass
ts=[threading.Thread(target=one) for _ in range(8)]
[t.start() for t in ts]; [t.join() for t in ts]
print("warmup done")
PY
