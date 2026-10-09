#!/usr/bin/env python3
"""Concurrency throughput probe with per-content-class prompts.

The aggregate rate on this engine depends on what the six sessions are asked
to do (MTP acceptance drives tokens per weight-streaming cycle), so every
number has to name the content. Six classes, one per session, or one shared
prompt (--same) for the deterministic case.

Reports per request: prompt tokens, completion tokens, engine decode_ms/token,
draft/accept, wall seconds; then the aggregate over the concurrent window.
"""
from __future__ import annotations

import argparse
import json
import threading
import time
import urllib.request

SEG = "第%s章讲述了山脉与河流。"


def filler(segs: int) -> str:
    return "".join(SEG % i for i in range(segs))


TASKS = [
    ("count",
     "Count from 1 to 400, one number per line, only numbers, no other text."),
    ("list",
     "\n请逐行列出前 60 章的行号与标题，每行一个。"),
    ("code",
     "\nWrite a Python implementation of a thread-safe LRU cache with TTL "
     "support, including type hints and a short usage example. Then add unit "
     "tests for eviction order and expiry."),
    ("prose",
     "\n请写一篇约 800 字的中文散文，主题是雨夜的山城，要求有具体的景物描写"
     "与人物心理，避免套话。"),
    ("math",
     "\nA train leaves station A at 08:15 travelling 72 km/h. Another leaves "
     "station B, 210 km away, at 08:45 travelling 88 km/h towards A. Compute "
     "the meeting time and distance from A, showing every step. Then answer: "
     "what if the second train were 15 minutes late?"),
    ("recall",
     "\n请复述上面文章中出现过的所有数字，按出现顺序逐行列出，每行一个数字。"),
]


def payload(model: str, prompt: str, max_tokens: int) -> bytes:
    return json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0,
    }).encode()


def call(base: str, model: str, prompt: str, max_tokens: int, out: dict,
         key: str, t0: float) -> None:
    rq = urllib.request.Request(base.rstrip("/") + "/v1/chat/completions",
                                data=payload(model, prompt, max_tokens),
                                headers={"Content-Type": "application/json"})
    try:
        started = time.time()
        r = json.loads(urllib.request.urlopen(rq, timeout=3600).read())
        u = r.get("usage", {}) or {}
        g = u.get("gufo", {}) or {}
        out[key] = {
            "prompt_tokens": u.get("prompt_tokens", 0),
            "completion_tokens": u.get("completion_tokens", 0),
            "decode_ms_per_tok": g.get("decode_ms", 0) / max(u.get("completion_tokens", 1), 1),
            "prefill_ms": g.get("prefill_ms", 0),
            "draft": u.get("draft_tokens"),
            "accepted": u.get("draft_tokens_accepted"),
            "start_offset": started - t0,
            "end_offset": time.time() - t0,
        }
    except Exception as exc:  # noqa: BLE001
        out[key] = {"error": repr(exc)}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:8080")
    ap.add_argument("--model", default="MiMo-V2.6-Flash-RL")
    ap.add_argument("--conc", type=int, default=6)
    ap.add_argument("--segs", type=int, default=250,
                    help="prefix filler segments (8.6 tok each)")
    ap.add_argument("--tokens", type=int, default=192)
    ap.add_argument("--same", action="store_true",
                    help="all sessions run the identical list prompt")
    ap.add_argument("--tag", default="run")
    args = ap.parse_args()

    prompts = []
    names = []
    for i in range(args.conc):
        if args.same:
            prompts.append("【会话 %d】%s" % (i, filler(args.segs)) +
                           "\n请逐行列出前 30 章的行号与标题，每行一个。")
            names.append("same%d" % i)
        else:
            name, task = TASKS[i % len(TASKS)]
            prompts.append("【会话 %d】%s%s" % (i, filler(args.segs), task))
            names.append(name)

    out: dict = {}
    t0 = time.time()
    threads = [threading.Thread(target=call,
                                args=(args.base, args.model, prompts[i],
                                      args.tokens, out, names[i], t0))
               for i in range(args.conc)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    wall = time.time() - t0

    total_tok = 0
    total_draft = 0
    total_acc = 0
    print("== conc=%d segs=%d tokens<=%d tag=%s ==" %
          (args.conc, args.segs, args.tokens, args.tag))
    for name in names:
        r = out.get(name, {})
        if "error" in r:
            print("  %-6s ERROR %s" % (name, r["error"]))
            continue
        total_tok += r["completion_tokens"]
        total_draft += r["draft"] or 0
        total_acc += r["accepted"] or 0
        print("  %-6s out=%3d decode=%6.2fms/tok prefill=%5.1fs draft=%s/%s "
              "span=[%.1f,%.1f]s" %
              (name, r["completion_tokens"], r["decode_ms_per_tok"],
               r["prefill_ms"] / 1000.0, r["draft"], r["accepted"],
               r["start_offset"], r["end_offset"]))
    ok = [out[n] for n in names if "error" not in out.get(n, {})]
    if ok:
        span = max(r["end_offset"] for r in ok) - min(r["start_offset"] for r in ok)
        print("  aggregate %d tok / %.1fs = %.1f t/s   draft %d/%d (%.2f)" %
              (total_tok, span, total_tok / span, total_draft, total_acc,
               (total_acc / total_draft) if total_draft else 0.0))
    print("  wall %.1fs  (json: %s)" %
          (wall, json.dumps({n: out[n] for n in names})[:0] + "<omitted>"))


if __name__ == "__main__":
    main()