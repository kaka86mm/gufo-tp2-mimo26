# gufo-tp2-mimo26

**MiMo-V2.6-Flash-RL (309B total / 15B active MoE) served as one 250 GB pool from two 128 GB AMD Strix Halo hosts — six 200K-token sessions, cold prefill from 711 down to 288 tok/s by depth, and a restart-safe prefix continuation cache that turns a 193K-token cold prefill (692 s) into 7.8 s.**

[中文文档](README.zh-CN.md) · built on [gufo](https://github.com/neuhaus/gufo) · transported by [gufo-tp2-tb4-rdma](https://github.com/kaka86mm/gufo-tp2-tb4-rdma)

Two Strix Halo hosts (Ryzen AI MAX+ 395, 128 GB unified memory each, gfx1151, ROCm) hold one MoE model between them: 48 layers, 256 experts with 8 active, MXFP4 weights, plus an MTP draft head (Q8_0, d=7). Every layer is split across the TP2 pair over USB4 / Thunderbolt-4 RDMA. The serving layer keeps six 200K-token sessions warm and spills prefix snapshots to a disk continuation cache that survives a restart.

## Measured results

Hardware: 2× Strix Halo (Ryzen AI MAX+ 395, gfx1151, 128 GB unified; the two boards differ — one has ~2.25 GiB less usable RAM, which is what sizes the context below), Ubuntu 24.04, kernel 7.0.0-34, ROCm 7.2.4, transport = the sibling repo's TB4 RDMA write striping. Model: MiMo-V2.6-Flash-RL MXFP4 + MTP draft.

**Cold prefill** (fresh prefixes, single stream):

| prompt tokens | wall | per token | rate |
|---|---:|---:|---:|
| 8,314 | 11.7 s | 1.41 ms | 711 tok/s |
| 18,513 | 25.4 s | 1.37 ms | 729 tok/s |
| 36,712 | 58.0 s | 1.58 ms | 633 tok/s |
| 79,911 | 186.2 s | 2.33 ms | 429 tok/s |
| 141,513 | 408.1 s | 2.88 ms | 347 tok/s |
| 192,910 | 692.0 s | 3.59 ms | 288 tok/s |

**Prefix continuation** (the same prompt again; the first line is RAM, the rest are a restart with only the disk cache left):

| prompt tokens | path | wall | restore | speed-up |
|---|---:|---:|---:|---:|
| 79,911 | L1 RAM | **1.2 s** | 0.17 s | 155× |
| 68,911 | L2 disk | **2.2 s** | 1.29 s | 60× |
| 141,513 | L2 disk | **25.5 s** | 4.76 s | 24× |
| 192,910 | L2 disk | **7.8 s** | 3.76 s | **89×** |

A 195K-token request that extends an existing 143K prefix only prefilled the 49,550-token delta (271.7 s instead of 692 s). Every needle placed at 60% depth came back correct through all of these paths.

**Decode** — single stream **34.7 t/s**, six-way counting **92.6 / 92.5 / 92.1 t/s** aggregate, mixed six-way cohort **55.0 t/s**. A 10-minute soak of back-to-back six-way cohorts ran 29/29 rounds clean at 73.0–92.8 t/s with GTT flat (106,397 → 106,479 MB).

**Concurrent prefill** — six sessions prefilling ~28.9K tokens each: all six complete, 173,604 tokens in 363.7 s = **477 tok/s aggregate**, 75% of the single-stream rate at that depth.

**Memory envelope** (10-second sampling on both hosts across the whole test) — GTT peak **106,999 MB, identical on both ranks**, minimum available RAM **7.8 GB (rank0) / 6.3 GB (rank1)**. The measured allocation-failure point is ~109.7 GB of GTT, so the shipped configuration sits ~3 GB below the wall. Full tables, the losing configurations and the methodology are in [docs/BENCHMARKS.md](docs/BENCHMARKS.md).

## What is ours and what is upstream gufo

This stack is a **fork of gufo that runs in production**, and it is worth being precise about the split. gufo's upstream provides the engine core (the llama.cpp-derived inference loop, samplers, the serving CLI), the TP2 transport and the KV/continuation-cache subsystem — that is the load-bearing half and it is not ours.

What this repository adds, and what the numbers above measure:

- **The MiMo-V2.6-Flash model support in the engine** — the 309B/15B MoE port (kernel routing, the MXFP4 expert paths, the sliding/full attention layer split, the MTP wiring) implemented for gufo.
- **The kernel and format optimisations** — a 4-bit dense sidecar graft (dense weights 6,583 MB → 3,485 MB at load), fp16 all-reduce (`GUFO_AR_F16`), a shared-KV decode attention (the 16 query heads of a KV head reuse staged rows through LDS: +48% at 65K depth), a depth latch that stops re-deciding the all-reduce width mid-stream (+43% at 70K), the wide prefill attention kernel and the fused MXFP4 MoE decode tier. [docs/OPTIMIZATIONS.md](docs/OPTIMIZATIONS.md) records all of them **including the ones that lost**.
- **The serving and lifecycle layer in this repository** — the launcher, the systemd supervisor (GTT runaway guard, peer-vanish kill, restore-from-rollback), the paired-readiness restore path, the L1/L2 continuation-cache promotion, and the acceptance suite that produced every number above.
- **The model-repacking line** (EXL3 / n-bit repacks) and the TB4 RDMA transport in the [sibling repository](https://github.com/kaka86mm/gufo-tp2-tb4-rdma).

Nothing here replaces gufo, and the MIT notice of upstream is preserved in [LICENSE](LICENSE).

## What's in the box

```
run/    start-tp2-mimo.sh      coordinated TP2 launcher (rank0 local, rank1 over ssh);
                              every knob is overridable, see run/env.sh
        env.sh                the documented parameter block the launcher sources
        bench/                the measurement suite: acceptance battery + prefill
                              ladder + concurrent prefill + soak, the L2 proof, and
                              the small harnesses they use
deploy/ mimo-supervisor.sh     the lifecycle owner: GTT guard, peer-vanish kill,
                              automatic restore when the pair is down and the peer
                              answers
        mimo-supervisor.service
        restore-prod.sh       stop both ranks, put the pinned binary back, start,
                              wait for a *paired* ready (health 200 AND the peer
                              process alive); takes an exclusive lock
        mimo-stop.sh          stop both ranks, escalate to SIGKILL
        warmup.sh             a short warm-up request the supervisor runs after a restore
docs/   CONFIGURATION.md       every flag and env var, its production value, its
                              default and why — start here
        OPTIMIZATIONS.md       the engine work, wins and losses, with measurements
        BENCHMARKS.md          full data incl. losing configurations and methodology
        PITFALLS.md            everything that bit us, so it doesn't bite you
```

## Quick start

1. Transport first: bring up the RDMA pair with [gufo-tp2-tb4-rdma](https://github.com/kaka86mm/gufo-tp2-tb4-rdma) and confirm `rdma_ready` in the engine log on its own. These scripts assume `usb4_rdma0` exists on both hosts.
2. Model files on **both** hosts (same paths): the MXFP4 trunk, the MTP draft, and the dense sidecar (`dense-full-q4_0.gguf`, the graft target of the dense-sidecar optimisation). Adjust `MODEL`, `MTP`, `DENSE_SIDECAR` in `run/env.sh`.
3. Build or copy the engine binary to `$HOME/gufo-mimo2-bin` on both hosts, and keep a pinned copy next to it (`gufo-mimo2-bin.splitk`) for the rollback path.
4. Edit `run/env.sh`: hosts, the TP control token (a shared secret — the same value on both ranks), model paths, and the two cache directories. Then launch: `SESSIONS=6 CONTEXT=204800 ./run/start-tp2-mimo.sh`, wait for the rendezvous and the load.
5. Put the lifecycle under systemd: copy `deploy/mimo-supervisor.service`, fix the paths, `systemctl enable --now mimo-supervisor`. From then on the supervisor restores the pair without you (and refuses to interfere while `/tmp/mimo-no-supervise` exists — the marker test windows hold).
6. Sanity-check with the bench suite: `./run/bench/perf-accept.sh` (battery, decode, six-way, mixed, needles, L2 restart proof), then `./run/bench/prod-full-test.sh` (adds the cold prefill ladder, the concurrent prefill and a 10-minute soak).

## Configuration

Every flag, its production value, its default and the trap behind it: [docs/CONFIGURATION.md](docs/CONFIGURATION.md). The five that matter most:

| knob | value here | why |
|---|---|---|
| `--sessions` / `--context` | `6` / `204800` | back-solved from the smaller host's RAM, not chosen for taste — see below |
| `--cache-disk` | rank0 `$HOME/cache-disk`, rank1 `/mnt/data1t/cache-disk` | the disk continuation cache; **must be a real directory** — a symlink is rejected at load time, and one host's root filesystem is too small for 28 GiB of snapshots |
| `--cache-disk-bytes` | `30064771072` (28 GiB) | six ~4 GB snapshots plus staging |
| `--cache-disk-staging-bytes` | `3221225472` (3 GiB) | a *cap*, not a reservation; too small silently refuses every snapshot bigger than it (a 200K prefix snapshots ~2.6 GB) |
| `--cache-ram-bytes` | `1073741824` (1 GiB) | the L1 RAM pool; its default ("half of free RAM, at most 32 GiB") can be sized at the wrong moment and reserves far too much |

The context is a memory equation, not a preference. Measured: `GTT ≈ 89.7 GB fixed (weights + workspace + MTP) + Σ sessions (344 MB + context × 12.3 KB per rank)`. Five sessions at 256K load at 107,507 MB of GTT and run; six at 256K need ~111 GB and die against the ~109.7 GB wall on the smaller board. Six sessions at 200K land at **106,397 MB measured** — about 1 GB *below* the 5×256K point and 3 GB below the wall, with 6.3 GB of free RAM left at the worst moment of the full test. That is the whole reason this repo ships 6×200K.

## Pitfalls

The collection is [docs/PITFALLS.md](docs/PITFALLS.md); three that cost real time:

- **A symlinked cache directory fails the load** (`TP disk cache directory: Not a directory`) and takes the whole pair down with it — `tp_pair_lost` on the other rank.
- **`--cache-disk-staging-bytes` below the snapshot size kills the disk cache silently**: the directory simply stops growing, and requests report `cache_miss_reason=no_checkpoint`, which reads like "this prefix has no checkpoint" instead of "your snapshot was refused".
- **Readiness is not `event=listening`**: it is printed before the KV for a 200K context is allocated, and rank0 answers `/health` even when its peer is gone (it exits about a minute later). The restore path here waits for health 200 *and* a live peer process, because a restore that reports success with rank1 dead is worse than one that reports failure.

## Reproducing the numbers

All measurements are client-side HTTP against `http://127.0.0.1:8080` except where a restart is named explicitly. `run/bench/perf-accept.sh` is the acceptance battery (quality cases, single/6-way/mixed decode, cold needles, an L1 replay, and a restart that proves the disk cache); `run/bench/prod-full-test.sh` adds the cold prefill ladder, six concurrent prefills with memory sampling on both hosts, and the soak. Both write their artefacts under `/tmp` and print a summary; the engine's own view (`prefill_tps`, `cache=`, `cached_tokens`, `cache_restore_ms`) is in `$HOME/logs/mimo-rank0.log`.

## Credits

Engine: [gufo](https://github.com/neuhaus/gufo) (MIT) — this repository is our deployment, tuning and measurement layer on top of it. Transport: [gufo-tp2-tb4-rdma](https://github.com/kaka86mm/gufo-tp2-tb4-rdma). Hardware: 2× AMD Ryzen AI MAX+ 395 (Strix Halo, gfx1151).