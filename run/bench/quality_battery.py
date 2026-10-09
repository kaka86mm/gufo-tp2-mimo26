#!/usr/bin/env python3
"""Quality battery for the requantized attn projections.

Runs a fixed prompt set against a live gufo mimo2 server, checks the tasks
with numeric/exact answers, and dumps every answer to a JSON so a run before
and a run after a weight change diff cleanly.

Usage: quality_battery.py OUT.json [--port 8080] [--max-tokens N]
"""
import json
import re
import sys
import time
import urllib.request

SEG = "第%s章讲述了山脉与河流。"


def build(count):
    return "".join(SEG % i for i in range(count))


CASES = [
    # (name, prompt, max_tokens, checker)
    ("counting",
     "从1开始数数，每行一个数字，只输出数字，不要其他任何文字，一直数到200。",
     320,
     lambda t: (str(sum(range(1, 201)))[:6], t)),
    ("needle_2k",
     build(250) + "\n请记住：秘密通行码是 7391。\n刚才埋在文章里的秘密通行码是多少？只回答数字。",
     64,
     lambda t: ("7391" if "7391" in t else "MISS", t)),
    ("needle_20k",
     build(2000).replace(SEG % 1700, "请记住：秘密通行码是 8823。" + SEG % 1700)
     + "\n刚才埋在文章里的秘密通行码是多少？只回答数字。",
     64,
     lambda t: ("8823" if "8823" in t else "MISS", t)),
    ("chinese_prose",
     "请用中文写一段关于山脉与河流的散文，二百字左右。",
     320,
     lambda t: ("len=%d" % len(t), t)),
    ("code_prime",
     "用 Python 写一个函数 is_prime(n) 判断整数是否为质数，然后说明它为什么能在 O(sqrt(n)) 内完成。只输出代码和一段解释。",
     400,
     lambda t: ("code" if ("def " in t and "sqrt" in t) else "NO_CODE", t)),
    ("math_multistep",
     "一个水池有甲、乙两个进水管。甲管单独注满需要 12 小时，乙管单独注满需要 18 小时。"
     "两管同时开 4 小时后关闭乙管，甲管继续注水，还需要多少小时注满？只给出算式和最终答案（分数或小数均可）。",
     400,
     lambda t: ("2/9" if ("2/9" in t or "0.222" in t or "0.22" in t) else "CHECK", t)),
    ("json_instruction",
     "先用一句话问候，然后输出一个 JSON 对象：{\"a\": 1, \"b\": [2, 3]}。JSON 必须与给定内容完全一致。",
     200,
     lambda t: ("json" if re.search(r'\{\s*"a"\s*:\s*1', t) else "NO_JSON", t)),
]


def call(prompt, max_tokens, port):
    body = json.dumps({
        "model": "MiMo-V2.6-Flash-RL",
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0,
    }).encode()
    rq = urllib.request.Request("http://127.0.0.1:%d/v1/chat/completions" % port,
                                data=body, headers={"Content-Type": "application/json"})
    t0 = time.time()
    r = json.loads(urllib.request.urlopen(rq, timeout=3600).read())
    dt = time.time() - t0
    m = r["choices"][0]["message"]
    blob = " ".join(str(v) for v in m.values() if v)
    return blob.strip(), r.get("usage", {}), dt


def main():
    out_path = sys.argv[1]
    port = 8080
    if "--port" in sys.argv:
        port = int(sys.argv[sys.argv.index("--port") + 1])
    results = {}
    for name, prompt, mx, check in CASES:
        try:
            text, usage, dt = call(prompt, mx, port)
            verdict, _ = check(text)
        except Exception as exc:                              # noqa: BLE001
            text, usage, dt, verdict = "ERR %s" % exc, {}, 0.0, "ERR"
        tps = usage.get("completion_tokens_per_second")
        results[name] = {"verdict": verdict, "text": text[:1500],
                         "usage": usage, "seconds": round(dt, 1),
                         "tps": tps}
        print("  %-16s %-10s %6.1fs %s t/s" %
              (name, verdict, dt, ("%.1f" % tps) if tps else "-"))
    json.dump(results, open(out_path, "w"), ensure_ascii=False, indent=1)
    print("saved %s" % out_path)


if __name__ == "__main__":
    main()