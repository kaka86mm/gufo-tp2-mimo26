# gufo-tp2-mimo26

Running MiMo-V2.6-Flash-RL across two AMD Strix Halo boxes.

The model is a 309B mixture-of-experts with 15B active per token (MXFP4 experts). It doesn't come close to fitting on one 128 GB box. On two it just barely does, and most of what I did over the last few weeks is about that "barely". Right now it serves six 200K-token sessions at once; cold prefill goes from 711 tok/s on a short prompt to 288 tok/s at 195K; and if I restart the server, a prefix it has seen before comes straight from a disk snapshot, so the 193K prompt that costs 692 s cold comes back in 7.8 s.

The engine is [gufo](https://github.com/neuhaus/gufo) (MIT), forked with a MiMo port and a lot of kernel work of mine. The link between the two boxes is my other repo, [gufo-tp2-tb4-rdma](https://github.com/kaka86mm/gufo-tp2-tb4-rdma). Those two are prerequisites. This repo is everything else: the launcher, the supervisor that keeps the pair alive, the benchmark scripts, and the notes.

## The numbers

Two AMD Ryzen AI MAX+ 395 boards (gfx1151, 128 GB unified memory each), Ubuntu 24.04, kernel 7.0.0-34, ROCm 7.2.4, transport is TB4 RDMA. The boards are not identical: one has 2.25 GiB less usable RAM, and that one decides the context size below. Model is MiMo-V2.6-Flash-RL MXFP4 with the Q8_0 MTP draft head (d=7).

All of it, one table:

| test | load | wall | rate | notes |
|---|---|---:|---:|---|
| cold prefill | 8,314 tokens | 11.7 s | 711 tok/s | |
| cold prefill | 18,513 tokens | 25.4 s | 729 tok/s | peak of the curve |
| cold prefill | 36,712 tokens | 58.0 s | 633 tok/s | |
| cold prefill | 79,911 tokens | 186.2 s | 429 tok/s | |
| cold prefill | 141,513 tokens | 408.1 s | 347 tok/s | |
| cold prefill | 192,910 tokens | 692.0 s | 288 tok/s | 40% of peak |
| prefill, extending an existing prefix | 49,550 new tokens on a 143K prefix | 271.7 s | | only the delta is computed |
| same prompt, RAM snapshot (L1) | 79,911 tokens | 1.2 s | | 155x; restore 0.17 s |
| same prompt after a restart (L2 disk) | 68,911 tokens | 2.2 s | | 60x; restore 1.29 s |
| same prompt after a restart (L2 disk) | 141,513 tokens | 25.5 s | | 24x; restore 4.76 s |
| same prompt after a restart (L2 disk) | 192,910 tokens | 7.8 s | | 89x; restore 3.76 s |
| decode, one stream | | | 34.7 tok/s | |
| decode, six counting streams | | | 92.6 tok/s | 92.6 / 92.5 / 92.1 across three runs |
| decode, six mixed streams | | | 55.0 tok/s | after a drain, see below |
| prefill, six at once | 173,604 tokens (6 x 28.9K) | 363.7 s | 477 tok/s | 75% of the single-stream rate at that depth |
| ten-minute soak | six streams back to back | | 73.0-92.8 tok/s | 29/29 rounds clean, GTT +82 MB |
| memory | 6x200K | | peak 106,999 MB GTT | 6.3 GB free at the worst moment; the wall is ~109.7 GB |

"Cold" means the prompt has never been seen by the process, so nothing is cached. Every restore figure is the engine's `cache_restore_ms`; every rate is client wall clock against `http://127.0.0.1:8080`. The prefill curve peaks at 18K and decays from there: 12 of the 48 layers are full attention and pay for the whole context, the other 36 only see 128 tokens of history. Every needle I buried in these prompts came back correct, through all of these paths. One caveat on the concurrency rows: they only mean anything after a drain. A mixed six-way taken right after another cohort reads 21 t/s, and right after a cold 59K prefill it reads 15.8 t/s, because it is queueing behind resident sessions.

Full tables with per-case engine evidence, the snapshot sizes, and the configs that lost: [docs/BENCHMARKS.md](docs/BENCHMARKS.md).

## What's mine and what's gufo's

gufo supplies the engine core, the TP2 transport and the whole continuation-cache subsystem. That's most of the hard parts, and none of it is mine.

What I wrote on top:

- The MiMo-V2.6-Flash port: MoE routing, the MXFP4 expert paths, the 12-full/36-sliding attention layout, the MTP hookup.
- Kernel and format work: a q4_0 dense sidecar that shrinks the dense weights from 6,583 MB to 3,485 MB at load, fp16 all-reduce, shared-KV decode attention (+48% at 65K depth), a depth latch that stops re-deciding the all-reduce width mid-request (+43% at 70K), the wide prefill attention kernel, the fused MXFP4 decode MoE.
- The serving and lifecycle layer in this repo: the launcher, the systemd supervisor (GTT guard, peer-vanish kill, auto-restore), the restore path that waits for a *paired* ready, the L1/L2 cache promotion.
- The benchmark suite. Every number above came out of these scripts.

The kernel work includes the losses, with measurements. I keep them in [docs/OPTIMIZATIONS.md](docs/OPTIMIZATIONS.md) mostly so I stop re-trying them.

## Layout

```
run/    start-tp2-mimo.sh      TP2 launcher (rank0 local, rank1 over ssh); every knob is overridable, see run/env.sh
        env.sh                 the parameter block, with comments
        bench/                 the measurement suite: acceptance battery, prefill ladder,
                              concurrent prefill, soak, the L2 proof, and the small harnesses
deploy/ mimo-supervisor.sh      the lifecycle owner: GTT guard, peer-vanish kill, automatic restore
        mimo-supervisor.service
        restore-prod.sh        stop both ranks, put the pinned binary back, start, wait for
                              health 200 AND a live peer; takes an exclusive lock
        mimo-stop.sh           stop both ranks, escalate to SIGKILL
        warmup.sh              one warm-up request the supervisor runs after a restore
docs/   CONFIGURATION.md       every flag and env var, its value here, and why
        OPTIMIZATIONS.md       engine work: what shipped and what lost
        BENCHMARKS.md          full tables, failed configs, methodology
        PITFALLS.md            everything that bit me
```

## Running it

1. Bring up the RDMA link first, following [gufo-tp2-tb4-rdma](https://github.com/kaka86mm/gufo-tp2-tb4-rdma), and confirm `rdma_ready` shows up in the engine log. These scripts assume `usb4_rdma0` exists on both hosts.
2. Put the model files on both hosts at the same paths: the MXFP4 trunk, the MTP draft, and the dense sidecar (`dense-full-q4_0.gguf`). Adjust `MODEL`, `MTP` and `DENSE_SIDECAR` in `run/env.sh`.
3. Build the engine binary and copy it to `$HOME/gufo-mimo2-bin` on both hosts. Keep a pinned copy next to it (`gufo-mimo2-bin.splitk`) for the rollback path.
4. Edit `run/env.sh`: hosts, the TP control token (a shared secret, identical on both ranks), model paths, and the two cache directories. Then `SESSIONS=6 CONTEXT=204800 ./run/start-tp2-mimo.sh`.
5. Put the supervisor under systemd: `deploy/mimo-supervisor.service`, fix the paths, `systemctl enable --now mimo-supervisor`. After that the pair recovers on its own. It stays out of the way while `/tmp/mimo-no-supervise` exists, which is how my test windows keep it from interfering.
6. Check everything with `./run/bench/perf-accept.sh` (battery, decode, six-way, mixed, needles, the L2 restart proof) and then `./run/bench/prod-full-test.sh` (adds the prefill ladder, concurrent prefill, and the 10-minute soak).

## The knobs that matter

Every flag and its trap is in [docs/CONFIGURATION.md](docs/CONFIGURATION.md). The five I'd get wrong first:

| knob | value | why |
|---|---|---|
| `--sessions` / `--context` | `6` / `204800` | back-solved from the smaller board's memory, see below |
| `--cache-disk` | rank0 `$HOME/cache-disk`, rank1 `/mnt/data1t/cache-disk` | the L2 disk cache. It must be a real directory: a symlink fails the load, and rank1's root filesystem is too small for 28 GiB of snapshots |
| `--cache-disk-bytes` | `30064771072` (28 GiB) | six snapshots of ~4 GB plus staging |
| `--cache-disk-staging-bytes` | `3221225472` (3 GiB) | a cap, not a reservation. Too small and it silently refuses every snapshot bigger than it (a 200K prefix snapshots ~2.6 GB) |
| `--cache-ram-bytes` | `1073741824` (1 GiB) | the L1 RAM pool. Its default ("half of free RAM, up to 32 GiB") can be computed at the wrong moment and reserve far too much |

Context is a memory equation, not a preference. Measured on these boxes, per rank:

```
GTT ~ 89.7 GB fixed (weights + workspace + MTP)
    + sum of sessions (344 MB + context x 12.3 KB)
```

5x256K runs at 107,507 MB. 6x256K needs about 111 GB and dies at ~109.7 GB during load. 6x200K lands at 106,397 MB measured, about 3 GB below the wall, with 6.3 GB of free RAM left at the worst moment of the full test. That is where 200K comes from.

## Things that will bite you

Full list in [docs/PITFALLS.md](docs/PITFALLS.md). Three that cost me the most time:

- A symlinked cache directory fails the whole load with `TP disk cache directory: Not a directory`, and the other rank follows it down with `tp_pair_lost`.
- `--cache-disk-staging-bytes` smaller than your snapshots kills the disk cache silently. The directory just stops growing and requests report `cache_miss_reason=no_checkpoint`, which reads like "no checkpoint for this prefix" instead of "your snapshot was refused". I shipped 256 MiB for a while and thought the cache was working.
- Readiness is not `event=listening`. That line shows up before the KV for a 200K context is allocated, and rank0 keeps answering `/health` for about a minute after its peer is gone. The restore path here waits for health 200 and a live peer process, because a restore that reports success with rank1 dead is worse than one that reports failure.

## Reproducing

Everything is client-side HTTP against `http://127.0.0.1:8080`, except the steps that name a restart. `run/bench/perf-accept.sh` and `run/bench/prod-full-test.sh` write their artifacts under `/tmp` and print a summary. The engine's own view of each request is in `$HOME/logs/mimo-rank0.log` (`prefill_tps`, `cache=`, `cached_tokens`, `cache_restore_ms`), and per-request details are in the response's `usage.gufo` block.

## Credits

Engine: [gufo](https://github.com/neuhaus/gufo) (MIT). Transport: [gufo-tp2-tb4-rdma](https://github.com/kaka86mm/gufo-tp2-tb4-rdma). Hardware: 2x AMD Ryzen AI MAX+ 395.