# Optimizations

Every optimisation this deployment carries, with its measurement, plus the ones that lost. The rule we work by: an optimisation is only real if a different script can measure it again, and a loss stays written down so nobody re-litigates it. Everything below was measured on the two Strix Halo hosts in this repository's own configurations, most of it while the service was live.

Verdicts: **SHIPPED** (in production today), **MEASURED** (quantified, kept as data), **CLOSED** (measured, will not be revisited without new hardware).

## Model and formats

**The MiMo-V2.6-Flash model support itself — SHIPPED.** gufo did not have this model; the port is ours. Geometry the kernels work against: hidden 4096, 48 layers, 64 query heads, `head_count_kv = [4,8,8,8,8,4,8,8]`, head dim 128, sliding window 128 with pattern `[0,1,1,1,1,0,1,1]` — i.e. **12 full-attention layers and 36 sliding ones**, which is why the KV bill and the prefill curve below have the shape they do. 256 experts, 8 active, `expert_ff` 2048, MXFP4. Under TP2 each rank keeps all 256 experts at half the FF width and its half of the KV heads, ≈80.4 GB of weights per rank.

**Dense sidecar graft — SHIPPED.** `GUFO_MIMO_DENSE_SC` grafts a 4-bit (q4_0) copy of the dense projections at load: **dense weights 6,583 MB → 3,485 MB** per rank (measured at every start; the log line is `DENSE_SIDECAR grafted 115 tensors`). Single-stream decode **+18%**, and the ~3 GB saved per rank is a large part of what made six 200K sessions fit. Higher-bitrate sidecars (q4_K) bought nothing measurable for the extra memory, so q4_0 is what ships.

**Low-bit repacking (EXL3 line) — MEASURED, part shipped.** A separate line of work repacks the model below MXFP4. The useful finding: **Sinkhorn-style balancing of the quantisation grid helps the dense weights (−20…26% reconstruction error) and does nothing for the experts (−1.5% — those matrices are already balanced)**. That is why expert bit-budget work here goes through imatrix calibration and dense work through hashing. The EXL3 2.27 bpw package was judged not worth porting into the serving path: at that bitrate the decode-side compute cost (92 G weights/s) becomes the second wall after bandwidth.

## Kernels and runtime

**Shared-KV decode attention — SHIPPED, default on.** The 16 query heads that share a KV head reuse the staged rows through LDS instead of re-reading them per head. At 65K context a single stream went **62.4 → 42.1 ms/token (+48%)**; at 262K the win is roughly 10× that in absolute terms, and six-way concurrency showed no regression. It carries an escape hatch (`GUFO_ATTN_SHARED=0`) because an optimisation you cannot switch off is an assumption, not an optimisation.

**fp16 all-reduce (`GUFO_AR_F16`) — SHIPPED.** The TP exchange ran in fp32 by default; the fix was a root cause, not a rounding knob, and it pays most when the batch is real: **+19%** on batched decode.

**Depth latch — SHIPPED.** Above ~32K context no all-reduce width wins any more, so the engine now decides the width once and latches it for the life of the request instead of re-deciding per step. **+43% at 70K depth.**

**The fused MXFP4 MoE decode tier — SHIPPED, and closed.** `mimo2_mmq_mxfp4_moe_gate_up_mid8_vec` / `…_down_sum8_vec` run at **87–94% of the measured memory wall** (in-process wall: 232.8–241 GB/s; the fused tier moves 202–223 GB/s). There is no headroom left in the decode MoE — the only lever there is fewer bytes per token. (An earlier "170 GB/s" figure came from the *unfused* path and was wrong; the correction is the whole reason we now measure the wall in-process in every harness.)

**The wide prefill attention kernel — MEASURED.** `MimoBatchAttentionWmmaKernel<64,32>` runs the 12 full-attention layers, and at 58.7K tokens those are **43.5 s of the 44.55 s** the whole attention path costs. It runs at ~15% of peak and is flat with depth, i.e. it is latency-exposed, not bandwidth-bound.

## Closed by measurement (do not re-litigate)

**Pipelined prefill attention (the "A′" rewrite) — CLOSED, it loses.** Restructuring the per-K-tile serial chain (QK → softmax → PV → state update) into a double-buffered pipeline cost **5.6–7%** wall time in two independent implementations (7208/7270 ms → 7757/7778 ms on 58,728 tokens). The first explanation — +12 VGPR of live QK fragments eating occupancy — was **falsified** by the second: removing those fragments moved VGPR 174 → 175, and the block turns out to be *LDS-capacity* limited (62,976 of 65,536 bytes ⇒ one block per CU = 16 waves/CU) while the register file at 174 VGPR still allows 35 waves/CU. The real cause is that on gfx1151 WMMA and VALU share execution pipes, so in-block phase overlap adds instructions without hiding latency. Three arithmetic paths were closed on the way: raising occupancy needs LDS ≤32 KB and halved VGPRs (a 4-wave/EU request fails to compile: `local memory (78864) exceeds limit (65536)`); split-K gains nothing because the grid serialises at one block per CU anyway; and instruction cuts are capped near −10% by the no-softmax ablation (which removed 31% of VALU for a 9.8% gain).

**MoE prefill tiles — CLOSED.** The routed prefill kernels sit at 56–69% (paired gate/up) and 41–46% (down) of a 49.5–53.6 TFLOPS in-process ceiling, with no thermal derating over 30-second sustains, and the shape of the load — not the kernel — explains the remaining gap to the decode tier's efficiency.

**Assorted — CLOSED.** An interior fast path in the attention kernel: **+78%** wall time (worse). Removing the softmax maths entirely: −9.8%. Removing the in-loop barriers: −2%. None of these are worth revisiting; each has a harness in the private tree that can be re-run in minutes if new hardware changes the premise.

## Serving layer (this repository)

**The L1/L2 continuation cache — SHIPPED, and the highest-leverage change in the deployment.** The engine has an in-RAM snapshot pool and a restart-safe disk store; we sized them for six 200K sessions, moved rank1's store onto its data disk, and then proved the paths with the suite in `run/bench/`. What it buys: a 193K-token prefix that costs 692 s cold comes back in **7.8 s** after a full restart (restore itself 3.76 s), a 141K prefix in 25.5 s, and a 64K prefix out of RAM in 1.2 s. The traps we had to clear to get there — a staging cap that silently killed every snapshot past ~20K tokens, the engine's refusal of a symlinked cache directory, the commit window a snapshot needs — are written up in [PITFALLS.md](PITFALLS.md), because they are the difference between "the feature exists" and "the feature works".

**The lifecycle layer — SHIPPED.** A systemd supervisor with a GTT runaway guard (the GPU's pinned pages are invisible to the OOM killer, so this guard is the only one that works), a peer-vanish kill, and automatic restore when the pair is down and the peer answers; plus a restore path that waits for *paired* readiness, takes an exclusive lock, escalates from SIGTERM to SIGKILL, and replaces the binary by atomic rename. Every one of those four properties was added in response to a specific production failure, dated in the commit messages.

**The measurement suite — SHIPPED.** `run/bench/` is deliberately part of the deliverable: the acceptance battery, the cold prefill ladder, the concurrent-prefill runner, the L2 restart proof and the soak. Every number in [BENCHMARKS.md](BENCHMARKS.md) came out of these scripts, and none of them needed a service restart except where the text says so.

## Transport

The RDMA layer — TB4/USB4 write striping over all rails, the integration kernel, the TB netdev quirks — is its own repository: [gufo-tp2-tb4-rdma](https://github.com/kaka86mm/gufo-tp2-tb4-rdma). Everything here assumes it is up and exposes `usb4_rdma0`.