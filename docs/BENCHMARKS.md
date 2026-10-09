# Benchmarks

Every number in this file came out of the scripts in `run/bench/`, against the shipped 6x200K configuration, on the two machines below. Client-side figures are HTTP wall clock against `http://127.0.0.1:8080`; engine-side figures are the engine's own log fields. If a number comes from a restart, the text says so. I didn't extrapolate anything; if I didn't measure it, it isn't here.

## The two machines

| | |
|---|---|
| Hosts | 2x AMD Ryzen AI MAX+ 395 (Strix Halo), gfx1151 iGPU, 128 GB unified memory each |
| Boards | rank0 FAEX1 (124.94 GiB usable), rank1 AXB35-02 (122.69 GiB). The smaller board is what binds the whole cluster. |
| OS / stack | Ubuntu 24.04, kernel 7.0.0-34, ROCm 7.2.4 |
| Transport | TB4/USB4 RDMA write striping (`usb4_rdma0`), from [gufo-tp2-tb4-rdma](https://github.com/kaka86mm/gufo-tp2-tb4-rdma) |
| Model | MiMo-V2.6-Flash-RL MXFP4: 309B total / 15B active MoE, 48 layers, 12 full-attention + 36 sliding-window-128 layers, 64 query heads, head dim 192 (QK) / 128 (V), 256 experts with 8 active, expert FF 2048 |
| Draft | MTP head, Q8_0, `d = 7` |
| Serving | TP2, `--sessions 6 --context 204800 --prefill-chunk 64 --max-pending-per-client 16`, L1 RAM 1 GiB, L2 disk 28 GiB, staging 3 GiB |

How to read the two kinds of numbers: client wall is what a caller feels (HTTP plus queueing plus the MTP decode loop). The engine's view of every request is in `$HOME/logs/mimo-rank0.log` (`prompt_tokens= prefill_tokens= generated_tokens= cache= cached_tokens= cache_restore_ms= ttft_ms= prefill_tps= decode_tps=`) and in the response's `usage.gufo` block. Every "restore" number below is the engine's `cache_restore_ms`; every rate is client wall. The prompts are Chinese filler with a needle planted at 60% depth.

## Cold prefill ladder

Single stream, cold: each rung uses a filler template that has never been used before, so nothing is cached. Source: `run/bench/prod-full-test.sh` phase D. The `prompt tokens` column is the engine's `usage.prompt_tokens`, not the script's estimate.

| prompt tokens | wall | per token | rate |
|---:|---:|---:|---:|
| 8,314 | 11.7 s | 1.41 ms | 711 tok/s |
| 18,513 | 25.4 s | 1.37 ms | **729 tok/s** |
| 36,712 | 58.0 s | 1.58 ms | 633 tok/s |
| 79,911 | 186.2 s | 2.33 ms | 429 tok/s |
| 141,513 | 408.1 s | 2.88 ms | 347 tok/s |
| 192,910 | 692.0 s | 3.59 ms | 288 tok/s |

The curve peaks at the 16K rung and decays from there: 195K runs at 288 tok/s, 40% of peak, with per-token cost up 2.5x. This is the full-attention bill, not a cache effect. The layers that see the whole context dominate the attention budget, and their per-call cost grows superlinearly with depth (harness: 1.5 ms per call at 17.5K, 5.3 ms at 35K, 10.5 ms at 70K). A separate acceptance run at 168.9K (82% of the window) took 503.8 s with a needle HIT and GTT flat at 104 GB the whole way. One rung overshot: 15,000 segments of a different template made 243,910 tokens and the engine refused it with `context_length_exceeded`. That is the guardrail working, not a failure ([PITFALLS #17](PITFALLS.md)).

## Prefix continuation

The engine keeps two continuation tiers: **L1**, an in-process RAM snapshot pool (`--cache-ram-bytes`), and **L2**, a restart-safe disk store (`--cache-disk`). Procedure: ask a cold prompt, let the snapshot commit, restart the pair, ask the identical prompt again. The L1 row is a replay inside the same process; every L2 row is a full restart with only the disk cache left.

| case | prompt tokens | cold | warm | restore | speed-up |
|---|---:|---:|---:|---:|---:|
| L1 RAM 64K | 79,911 | 186.2 s | **1.2 s** | 0.17 s | 155x |
| L2 disk 68.9K | 68,911 | 131.8 s | **2.2 s** | 1.29 s | 60x |
| L2 disk 141K | 141,513 | 408.1 s | **25.5 s** | 4.76 s | 24x |
| L2 disk 193K | 192,910 | 692.0 s | **7.8 s** | 3.76 s | **89x** |
| incremental | 195K request on an existing 143K prefix | — | only 49,550 tokens prefilled, 271.7 s | — | — |

Engine evidence for each row, from `$HOME/logs/mimo-rank0.log`:

- L1: `cached_tokens=79911 prefill_tokens=0 restore=167.8ms`
- 68.9K: `cache=disk cached_tokens=68911 prefill_tokens=0 cache_restore_ms=1292.1 ttft_ms=1305.9`
- 141K: `cache=disk cached_tokens=141513 cache_restore_ms=3038.3`, needle HIT (first pass). The 25.5 s row above is a later re-check on the same machine with a 4.76 s restore, and after rank1's store moved to `/mnt/data1t/cache-disk` the same prefix restored in `cache_restore_ms=3165.6`. This prefix has three restored measurements and they disagree, which is why the table quotes the slow one.
- 193K: `cached_tokens=192910`, restore 3.76 s, needle HIT

First proof of the L2 path at all (7.8K prefix, from `run/bench/l2-cache-test.sh`): cold 11.24 s, then after restarting both ranks, `cache=disk cached_tokens=7764 prefill_tokens=0 cache_restore_ms=185.3 ttft_ms=190.4`, answer byte-identical, snapshot 118 MB on each host.

**Snapshot sizes** (roughly `context x 12.3 KB` per rank, plus overhead):

| prefix tokens | snapshot | note |
|---:|---:|---|
| 7,764 | 118 MB | first L2 proof |
| 68,911 | 984 MB | 984,386,573 B on disk |
| 141,513 | 2.0 GB | |
| 192,910 | 2.73 GB | ~2.6 GB is what a full 200K prefix costs, which is what sizes `--cache-disk-staging-bytes` |

One thing that cost me an afternoon: a snapshot is not usable the moment the file appears. Kill the engine seconds after a large snapshot lands and the next start reports `cache_miss_reason=no_checkpoint` and prunes the file; give it ~2 minutes of idle and the same prefix hits. Measured both ways on the 193K prefix. See [PITFALLS #4](PITFALLS.md).

## Decode

MTP speculative decoding (`d = 7`) is active in all of these. Content matters a lot here: the aggregate rate depends on what the sessions are asked to do, because MTP acceptance drives how many tokens come out of one weight-streaming cycle. So every row names the content.

| scenario | aggregate | notes |
|---|---:|---|
| single stream | 34.7 t/s | mixed content, steady state |
| six-way counting, run 1 | 92.6 t/s | three consecutive cohorts of the same counting prompt |
| six-way counting, run 2 | 92.5 t/s | |
| six-way counting, run 3 | 92.1 t/s | |
| mixed six-way cohort | 55.0 t/s | six different task classes (count / list / code / prose / math / recall) |
| older 8x98304 config | 91.7 / 91.4 / 91.1 t/s | the previous production shape, for reference |

The mixed figure has to be measured after a drain. Taken right after another six-way cohort it reads **21 t/s**, and taken immediately after the 58.7K cold prefill it reads **15.8 t/s**. Both of those are queueing behind resident sessions, not decode (see Measurement traps).

## Concurrent prefill

`run/bench/prod-full-test.sh` phase F: six requests fired at once, each ~1,800 filler segments with `max_tokens=1` and a needle at 50% depth. The run measured **173,604 prompt tokens in total (~28.9K each)**, **all six completed**, wall 363.7 s, so **477 tok/s aggregate**. Single-stream rate at that depth is 633 tok/s (the 32K rung), so this is **75% concurrency efficiency at 6x**, in the production configuration and at the production session count.

## Ten-minute soak

Ten minutes of back-to-back six-way counting cohorts (`clean-bench.py 6 256`, 2 s between rounds), with the memory sampler running on both ranks:

- rounds: **29, clean 29/29**
- aggregate: **73.0 - 92.8 t/s** (the spread is cohort-to-cohort MTP acceptance, not drift)
- GTT: **106,397 → 106,479 MB (+82 MB)**. Noise, no leak.
- minimum free RAM over the whole test (ladder + concurrent + soak): rank1 6.3 GB

## Memory envelope

Sampled every 10 seconds on both ranks (`mem_info_gtt_used` + `MemAvailable`), 400 samples each, across the entire full test: ladder, concurrent prefill, soak.

| metric | rank0 | rank1 |
|---|---:|---:|
| GTT, steady state (6x200K) | 106,397 MB | 106,397 MB |
| GTT peak over the whole test | 106,999 MB | 106,999 MB |
| minimum available RAM | 7.8 GB | 6.3 GB |
| allocation-failure point (measured) | — | 109,700 MB |

The memory model, back-solved from the machines:

```
GTT ≈ 89.7 GB fixed (weights + workspace + MTP)
    + Σ sessions (344 MB + context × 12.3 KB per rank)
```

Anchors: five sessions at 256K load and run at **107,507 MB** (and that is *worse* than 6x200K, which is 106,397 MB: more sessions, lower GTT). Six at 256K need about **111 GB** and die; the kernel global-OOMs the load at **109,717 MB** (`kfd_ioctl_alloc_memory_of_gpu → ttm_pool_alloc_page`), which is the wall. Six at 200K were predicted at 106.8 GB and measured at **106,397 MB** (0.4 GB error), so **2.7 GB below the wall at the peak of the full test**. The binding constraint is rank1's board, which has 2.25 GiB less usable RAM than rank0.

One thing to keep in mind: a rank's RSS sits around 0.5 GB while its GTT holds 106 GB, so a watchdog watching process memory sees nothing. Sample `mem_info_gtt_used`, not MemUsed.

## Losing configurations and null results

Measured so you can skip them. Δ is against the incumbent on the same harness.

| change | measurement | Δ | what happened |
|---|---|---|---|
| Pipelined prefill attention ("A′"), two implementations | 7,208 / 7,270 ms → 7,757 / 7,778 ms at 58,728 tokens | **+5.6–7% (a loss)** | closed |
| Occupancy hypothesis for A′ | LDS 62,976 of 65,536 B, so 1 block/CU = 16 waves/CU; VGPR 174 (175 after removing the fragments) still allows 35 waves/CU | hypothesis wrong | closed |
| 4 waves/EU occupancy build | does not compile: `local memory (78864) exceeds limit (65536)` | — | closed |
| split-K on the attention grid | 58.7K: splits 2/4 = 7,363 / 7,355 ms before merge cost; 70K: splits 32, n=2 10.5 → 16.5 ms/layer, decode 1,163 → 1,594 ms | −4.5% / worse | closed |
| "interior" fast path in the QK^T epilogue | full layers 7,182 → 12,796 ms; window-128 arm 70.5 → 332.5 ms | **+78% / +370%** | reverted |
| softmax removed entirely (ablation) | −9.8% wall while removing 31% of VALU instructions | ceiling ≈ −10% | closed |
| alternative wide-attention shapes (vs 64x32 = 1.00) | 32x32 = +23%, 32x16 = +47%, 16x64 = +165% | worse | closed |
| WMMA path for narrow decode widths (`WIDE_MIN=2`) | 19.6–20.0 t/s vs 23.5–23.8 at `WIDE_MIN=16`; decode 1,286 → 1,133 ms | +18% by reverting | reverted to 16 |
| batched key loading in the attention kernel | 1.606 vs 1.603 ms/layer at 35K | dead | knob kept, default off |
| KV int8 | attention at 96K runs at ~45% of the L2 bandwidth wall (~600 GB/s of ~1.2 TB/s), and the multi-row calls (70% of the cost at 70K) barely scale with bytes, so halving KV buys only 1.2–1.4x for a six-place change | deprioritised | measured |
| MoE decode tier headroom | fused tier moves 202–223 GB/s against a same-run self-measured wall of 232.8–241 GB/s | 87–94% of the wall | closed |
| EXL3 2.27 bpw expert repack | bytes 5.16 GB/token → ~2.70 GB (−52%), but decode needs ≥500 G weights/s against my 92 | not ported | measured |
| Sinkhorn reparameterisation of the quantisation grid | experts −1.5%; dense `gate_proj` −26%, router −23% | experts: no | measured |

Four of these deserve the numbers written out.

**6x256K does not fit, and that is a hardware fact, not a flag.** The need is ~111 GB of pinned GTT; the smaller board fails the allocation at 109,717 MB, and the kernel OOM that follows takes out `sshd` and `rsyslogd` before it finishes with the engine. Swap does not help; the pages are GPU-pinned, not swappable. 5x256K runs at 107,507 MB. The shipped context is back-solved from what loads with margin, which is why it is 6x200K and not a rounder number ([CONFIGURATION.md](CONFIGURATION.md) has the back-solve).

**Pipelined prefill attention (A′) is closed on mechanism, not just on numbers.** The rewrite loses 5.6–7% in two independent implementations, and the reason it was supposed to win (occupancy) is provably not the constraint: the block is LDS-capacity limited (62,976 of 65,536 bytes, one block per CU) while the register file at 174 VGPR would allow 35 waves/CU. The actual cause is that on gfx1151 WMMA and VALU share execution pipes, so overlapping phases inside a block adds instructions without hiding latency. Raising occupancy would need LDS ≤32 KB and halved VGPRs, and the 4-wave/EU build does not compile. Instruction cuts only reach about −10% (the softmax-removal ablation), short of where I'd promote a rewrite. The kernel stays behind `GUFO_ATTN_PIPE` (default off) so it can be re-tested.

**EXL3 2.27 bpw: bytes are not the only wall.** The byte budget is real (5.16 GB/token of weights → ~2.70 GB, −52%; predicted single stream 43.8 ms → ~31 ms = 32 t/s, six-way batch step 133 → 95 ms ≈ 94 t/s). What stops it is decode-side compute: my HIP decode reaches 92 G weights/s (after fixing a `__constant__` table with divergent access that cost 32x serialisation: bit-loop 15 G/s → table 40 G/s → table-free ring 92 G/s), while reproducing exllamav3's dp4a-packed inner kernels needs ≥500 G weights/s for its 26 ms/token. That is 5.5x mine, and it scales with rows x slots while bytes scale with distinct experts. A single machine could serve the model at that bitrate; this deployment cannot afford the compute per token. Quality at 2.27 bpw was indistinguishable from my MXFP4 4.3 bpw on the tasks I ran (GSM8K identical, HumanEval+ within 2 questions at n=60). One caution from the artifact's own card: ppl 5.4003 belongs to the 2.27 bpw build, 89.63 / 95.8 to a 2.36 bpw build with no baseline. Don't mix those numbers.

**Sinkhorn helps the dense path and does nothing for the experts.** Measured per-tensor on the trunk, 3-bit / group 32, relRMS plain vs Sinkhorn: routed experts move −1.5% (0.1650 → 0.1629; their row/column RMS spread is only 1.5–4.8, and the method's whole mechanism is flattening imbalance, so there is nothing to flatten), while unbalanced dense tensors move a lot: `L0.mlp.gate_proj` −26% (0.2741 → 0.2039), router `L24.mlp.gate` −23%, dense down projection −3%, attention 0%. So expert bit-budget work goes through imatrix-style calibration and Sinkhorn is a dense-path tool. Probe caveat: it uses 32-group min/max round trips, coarser than Q3_K's 6-bit sub-block scales, so the absolute relRMS numbers are pessimistic; the plain-vs-Sinkhorn comparison is the stable part.

## Which script produces which number

| script | what it produced |
|---|---|
| `run/bench/perf-accept.sh` | acceptance battery: quality cases, single-stream decode, six-way counting x3, mixed cohort after a 20 s drain, cold ~59K needle, cold near-max needle with GTT sampling, L1 replay, and the restart + re-ask that proves L2 at 68.9K |
| `run/bench/prod-full-test.sh` | the full record: cold prefill ladder, L1 replay at 64K, six concurrent prefills, L2 restart at 176K, ten-minute soak, and the 10-second memory sampler on both ranks |
| `run/bench/l2-cache-test.sh` | the minimal L2 proof, the first promotion evidence, at a 7.8K prefix |
| `run/bench/clean-bench.py` | counting-cohort harness; the aggregate is computed over the cohort span (max end − min start), which is what makes it 92 t/s and not 6x34.7 |
| `run/bench/conc_mixed.py` | mixed-content cohort: one task class per session, reports per-request prompt/completion, engine `decode_ms/token`, draft/accept, and the aggregate |
| `run/bench/quality_battery.py` | correctness battery (counting, needles). It runs before any of the above counts. |

All benches talk to rank0 over HTTP; only the L2 phases restart the pair, through `deploy/restore-prod.sh`, and the text says so when they do. Use client wall for what a caller feels and the engine log for what actually happened. When the two disagree, the engine log wins for facts and the client wall wins for experience, which is why both are recorded.

## Measurement traps

1. **"Cold" means virgin.** Each cold rung uses a filler template never used before. Templates are not interchangeable: re-using one from a previous script turns the run into a cache hit and the "cold" rate into a restore rate.
2. **A snapshot needs to commit.** The file appearing is not the snapshot being usable; restarting too early loses it and prunes it (see [PITFALLS #4](PITFALLS.md)). Every L2 number above was taken after the commit window.
3. **Concurrency cohorts must drain.** A mixed six-way taken right after another cohort reads 21 t/s, and right after the 58.7K cold prefill it reads 15.8 t/s. The clean figure is 55.0 t/s. Drain before measuring, and measure mixed cohorts *before* the large prefills, never after.
4. **Never predict prompt length from segment count.** The filler's token ratio depends on the template and the width of the index (11.7–16.3 tokens per segment measured here). Read `usage.prompt_tokens` from a real response. One early helper of mine printed `approx_tokens = segments × 1.43`, an ~8x underestimate, and a 15,000-segment rung came out at 243,910 tokens and was rejected ([PITFALLS #17](PITFALLS.md)).
5. **Watch GTT, not RSS.** A rank holds ~106 GB of pinned GTT with ~0.5 GB of RSS. Sample `mem_info_gtt_used` on both ranks, every 10 seconds, for the whole run; that is how the envelope table above was produced.