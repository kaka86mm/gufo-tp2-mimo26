# Optimizations

All the engine-side work this deployment carries, with the measurement for each, plus the ones that lost. My rule: an optimisation only counts if a separate script can measure it again, and a loss stays written down so I don't re-try it next month. Everything below was measured on the two Strix Halo hosts, most of it with the service live.

Tags: **SHIPPED** (running in production), **MEASURED** (quantified, kept as data), **CLOSED** (measured, not revisiting without new hardware).

## Model and formats

**MiMo-V2.6-Flash support itself — SHIPPED.** gufo doesn't have this model; the port is mine. The geometry the kernels work against: hidden 4096, 48 layers, 64 query heads, `head_count_kv = [4,8,8,8,8,4,8,8]`, head dim 128, sliding window 128 with pattern `[0,1,1,1,1,0,1,1]`. That is 12 full-attention layers and 36 sliding ones, and that split is why the KV bill and the prefill curve look the way they do. 256 experts, 8 active, `expert_ff` 2048, MXFP4. Under TP2 each rank keeps all 256 experts at half the FF width plus its half of the KV heads, about 80.4 GB of weights per rank.

**Dense sidecar — SHIPPED.** `GUFO_MIMO_DENSE_SC` grafts a q4_0 copy of the dense projections at load: dense weights 6,583 MB → 3,485 MB per rank (the log line is `DENSE_SIDECAR grafted 115 tensors`). Single-stream decode +18%, and the ~3 GB saved per rank is a big part of why six 200K sessions fit at all. I tried q4_K sidecars; they bought nothing measurable for the extra memory, so q4_0 is what ships.

**Low-bit repacking (EXL3 line) — MEASURED, not shipped.** A separate line of work repacks the model below MXFP4. The finding that mattered: Sinkhorn-style balancing of the quantisation grid helps the dense weights (−20…26% reconstruction error) and does nothing for the experts (−1.5%; those matrices are already balanced). So expert bit-budget work here goes through imatrix-style calibration, and Sinkhorn stays a dense-path tool. The EXL3 2.27 bpw package was judged not worth porting into the serving path: at that bitrate the decode-side compute cost becomes the second wall after bandwidth.

## Kernels and runtime

**Shared-KV decode attention — SHIPPED, on by default.** The 16 query heads that share a KV head reuse the staged rows through LDS instead of re-reading them per head. At 65K context a single stream went **62.4 → 42.1 ms/token (+48%)**; at 262K the absolute saving is about 10x that, and six-way concurrency showed no regression. It has an escape hatch (`GUFO_ATTN_SHARED=0`) because an optimisation you cannot switch off is an assumption.

**fp16 all-reduce (`GUFO_AR_F16`) — SHIPPED.** The TP exchange ran in fp32 by default. Fixing that was a root-cause fix, not a rounding knob, and it pays most when the batch is real: **+19%** on batched decode.

**Depth latch — SHIPPED.** Above ~32K context no all-reduce width wins any more, so the engine now decides the width once per request and latches it instead of re-deciding every step. **+43% at 70K depth.**

**Fused MXFP4 decode MoE — SHIPPED, and closed.** `mimo2_mmq_mxfp4_moe_gate_up_mid8_vec` / `…_down_sum8_vec` run at **87–94% of the measured memory wall** (in-process wall: 232.8–241 GB/s; the fused tier moves 202–223 GB/s). There is no headroom left in the decode MoE; the only lever is fewer bytes per token. An earlier "170 GB/s" figure came from the *unfused* path and was wrong, which is why every harness now measures the wall in-process.

**Wide prefill attention kernel — MEASURED.** `MimoBatchAttentionWmmaKernel<64,32>` runs the 12 full-attention layers, and at 58.7K tokens those are **43.5 s of the 44.55 s** the whole attention path costs. About 15% of peak, flat with depth, so it is latency-exposed rather than bandwidth-bound.

## Closed by measurement (do not re-litigate)

**Pipelined prefill attention (the "A′" rewrite) — CLOSED, it loses.** Restructuring the per-K-tile serial chain (QK → softmax → PV → state update) into a double-buffered pipeline cost **5.6–7%** wall time in two independent implementations (7,208/7,270 ms → 7,757/7,778 ms on 58,728 tokens). The first explanation, +12 VGPR of live QK fragments eating occupancy, was disproved by the second implementation: removing those fragments moved VGPR 174 → 175, and the block turns out to be LDS-capacity limited anyway (62,976 of 65,536 bytes, so one block per CU) while the register file at 174 VGPR would allow 35 waves/CU. The real cause is that on gfx1151 WMMA and VALU share execution pipes, so overlapping phases inside a block adds instructions without hiding latency. Three arithmetic paths closed on the way: higher occupancy needs LDS ≤32 KB and halved VGPRs (a 4-wave/EU build does not compile: `local memory (78864) exceeds limit (65536)`); split-K gains nothing when the grid serialises at one block per CU; and instruction cuts cap around −10% (the no-softmax ablation removed 31% of VALU for a 9.8% gain).

**MoE prefill tiles — CLOSED.** The routed prefill kernels sit at 56–69% (paired gate/up) and 41–46% (down) of a 49.5–53.6 TFLOPS in-process ceiling, with no thermal derating over 30-second sustains. The remaining gap to the decode tier's efficiency is the shape of the load, not the kernel.

**Assorted — CLOSED.** An interior fast path in the attention kernel: **+78%** wall time (worse). Removing the softmax maths entirely: −9.8%. Removing the in-loop barriers: −2%. None of these are worth another attempt; each has a harness in my private tree that can re-run in minutes if new hardware changes the premise.

## Serving layer (this repository)

**The L1/L2 continuation cache — SHIPPED.** The engine has an in-RAM snapshot pool and a restart-safe disk store; I sized them for six 200K sessions, moved rank1's store onto its data disk, and proved the paths with the suite in `run/bench/`. What it buys: a 193K-token prefix that costs 692 s cold comes back in **7.8 s** after a full restart (restore itself 3.76 s), a 141K prefix in 25.5 s, a 64K prefix out of RAM in 1.2 s. The traps I had to clear to get there (a staging cap that silently killed every snapshot past ~20K tokens, the engine's refusal of a symlinked cache directory, the commit window a snapshot needs) are in [PITFALLS.md](PITFALLS.md). Getting the cache actually working was a bigger deal than any single kernel.

**The lifecycle layer — SHIPPED.** A systemd supervisor with a GTT runaway guard (the GPU's pinned pages are invisible to the OOM killer, so this guard is the only one that works), a peer-vanish kill, and automatic restore when the pair is down and the peer answers; plus a restore path that waits for *paired* readiness, takes an exclusive lock, escalates from SIGTERM to SIGKILL, and swaps the binary by atomic rename. Every one of those four properties was added after it failed in production.

**The measurement suite — SHIPPED.** `run/bench/` is deliberately part of the deliverable: the acceptance battery, the cold prefill ladder, the concurrent-prefill runner, the L2 restart proof, the soak. Every number in [BENCHMARKS.md](BENCHMARKS.md) came out of these scripts.

## Transport

The RDMA layer (TB4/USB4 write striping over all rails, the integration kernel, the TB netdev quirks) is its own repository: [gufo-tp2-tb4-rdma](https://github.com/kaka86mm/gufo-tp2-tb4-rdma). Everything here assumes it is up and that `usb4_rdma0` exists.