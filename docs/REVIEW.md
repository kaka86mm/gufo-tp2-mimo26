# Where the build stands, and what is left

I wrote this in October 2026, after the TP2 pair was stopped and the boxes went to another serving line. It is the re-entry plan: the measured status, the levers that are dead, and the one path I would still take. Every number here has a harness or a log line behind it in the private tree; nothing is extrapolated unless it says so.

## Status

- Pair: two Strix Halo boards, TP2 over the RDMA rails, six 200K sessions, MTP limit 7, L2 64 GiB per rank, 6 GiB staging. The last production run peaked at 106,396 MB GTT against a measured 109,717 MB wall.
- Single stream: 29.2–30.1 t/s at 1K, 31.5–32.6 at 8K, 29.3 at 28K, 23.6 at 55K, 19.4–21.0 at 110K, 13.7–19.3 at 150K. The 30 target is met up to 8K and nowhere else.
- Six sessions: 85.5–86 aggregate at 1K, 52–53.6 at 55K, 36 at 110K. The 90 target holds only for short, counting-like traffic.
- 500K: one or two sessions load and run; six do not fit. A 500K needle has not been run. Cold prefill extrapolates to 45–50 minutes; after the first turn the continuation cache turns a 150K replay into 33 ms–4 s.
- Step model at six sessions: `a + b*W`, with a = 30–33 ms and b = 6.6 / 14.1 / ~21 ms at 1K / 55K / 110K. The marginal is the lane's own nine full-attention layers plus its expert traffic.
- Prefill: 682 → 238 t/s from 8K to 150K. Mixing prefill with decode costs only 2% at prefill-chunk 2048.

## Why six-way 90 is a bytes problem

Six mixed lanes route to about 15 GB of expert weights per cycle. At the measured 224 GB/s wall that is 67 ms; the fixed part is another ~30 ms, so a cycle costs ~100 ms even if attention were free. 90 t/s needs 66.7 ms total. No kernel change closes that: the only lever is fewer bytes per token, which means a lower-bit expert format. The same wall was measured directly at six lanes: 222–227 GB/s, 99% of the in-process ceiling.

At depth the picture gets worse. At 110K the per-lane full-attention cost is ~14 ms of the 21 ms marginal; six lanes of that alone is 84 ms, past the 90 t/s budget before any expert byte is read. So 90 at 110K is not a weight-format problem either: it would need a faster attention kernel as well.

## Quality sets the floor

I am not willing to ship 2.27 bpw to make the numbers. The evidence:

- In this engine, a 2.27 bpw expert sidecar produced correct JSON, needle answers and Chinese definitions, but "repeat this exactly" drifted into HTML and counting degenerated into repetition. That was a quality regression, not a kernel bug.
- Against FP8, the best third-party 2.27 bpw build scores HumanEval+ 88.4 vs 90.2, MBPP+ 77.2 vs 77.2, GSM8K 95.2 vs 96.4, MMLU-Pro 73.8 vs 76.4, GPQA-D 50.0 vs 56.2. That is a good 2.27, and it is still a measurable drop.
- A 60-question cross-engine A/B (2.27 vs the 4.3 bpw MXFP4 build) came out 57/60 vs 57/60 on GSM8K and 58 vs 56 on HumanEval+. At n=60 that only says the difference is small; it is not an agent or tool battery.

So the production floor is 3.0 bpw: 114 GB of experts, about 65 GB of weights per rank, which still leaves room for six 200K sessions or two 500K ones. A single box cannot hold 3.0 bpw (114 + ~15 other + ~12 runtime > 122.88 GB GTT), so dropping TP2 would require 2.27 and is off the table while quality is the constraint.

Under the 3.0 floor the expert term drops ~29% and attention does not. My estimate is six-way 90–100 at short context, 63–70 at 55K, 44–50 at 110K; single 30–33 short, 23–25 at 110K. At 55K even 2.27 only reaches ~70–80 in the same model, and 90 would need the batch overhead to shrink as well. If quality is a hard constraint, the 90 target exists only at short context.

## The one path I would still take

Port the EXL3 MoE kernels from the private experimental branch into the 0.15.0 serving tree, then fix the batch path. The assets are already on disk: a 3.0 bpw expert sidecar (114 GB) on both hosts, and the 2.27 bpw one as a research arm only. The kernel measured 542 G weight/s (~80% of the wall) in isolation; the reason the 3.0 build was not shipped is the batched path, where it ran 61.9 t/s against MXFP4's 90.6 at six lanes. MTP acceptance was 5–16 points lower because the drafter does not match the re-quantized trunk.

The work is the port plus the batch kernel: token tiling, ring tables, vectorized gate/up/down, targeting MXFP4's 150–179 GB/s effective bandwidth. Then the battery. My gate is GSM8K 100, HumanEval+ 100, the enum and tool-call sets, and a 60K needle, all within noise of MXFP4. Counting and exact-repeat are the known weak spots. If the 55K number lands below 60 or the battery regresses, the answer is to stay on MXFP4 and leave the pair parked; the port is not worth it.

Budget: 2–4 guarded windows. The pair is stopped; an experiment means stopping the other serving line, running a test copy of the binary (never overwriting production), and restoring afterwards.

## Dead levers (do not re-litigate)

- MTP policy: the C1 cycle ratio is 1.37–1.40 and the 32K depth latch is correct. Forcing a draft width at depth loses 21–46% even at 90.5% acceptance; a 2K draft window recovers +9/+13% and is still net-negative; 0.80 vs 0.62 cost scale is inside the noise.
- Attention: the split count is optimal at 32 (64 changes nothing); forcing the width loses; the shared-KV kernel is best at split 32; 64x32 is the best tile; the interior fast path cost +78%; KV int8 regresses to the per-head kernel and adds 8.6 GB for 15–20% of a step.
- Graph capture: −40%. Replay kernels are slower (498 vs 931 µs on the same grid).
- Two-lane micro-batching: negative, default off.
- Q3_K experts: 0.809× the bytes for 1.36× the cycle and broken quality.
- Dense projections: 199 GB/s, at the wall; three kernel attempts failed.
- Prefill chunk: 2048 already removes the interleave penalty; 64 vs 2048 was identical at 8K and 32K.

## DFlash, for the record

DFlash is not an untried lever; it was taken end-to-end in October. Acceptance was p1 0.826 and conditional p2 0.642 (the vLLM reference is 0.71/0.46). With the fused MoE it did 29.0–30.8 t/s single-stream (counting 35–40, code 26–32, prose 21–23), but six-way serial was 19.6, and the batched DFlash-AR path was 33% slower than the engine's plain AR (125 vs 94 ms/cycle). The 0.15.0 serving tree still disables snapshot, fork, prefix-reuse and persistence for DFlash and runs plain AR rows in batch by design. It is a short-context single-stream niche, not the main lever.

## Cheap work that is still worth doing

- Merge the six per-session logits readbacks into one, or use the device-side argmax for greedy: 1.25 ms/cycle plus ~1 ms of CPU.
- Coalesce the ~97 exchange operations per cycle (about 100 µs of fixed cost each; the worker is idle 31% of the time). Two lanes failed, but payload aggregation was never tried. Target 3–5 ms.
- 2050 kernels per cycle at 2.7 µs each is 5.5 ms of launch holes; fuse norm/rope/quantize. Graph capture is not the answer.
- The router is 3.85 ms/cycle at six lanes; an LDS-resident kernel could save ~2 ms.
- Realistic total: six-way counting 86 → 92–95, mixed 50 → 55. It does not reach 90.

## Two stability issues still open

1. Snapshot-write contention. The same 55K probe returned 23.95 / 22.44 / 15.84 t/s; the slow run followed two 110K requests whose ~1.3 GB snapshots were being written to L2. Instrument write time against the decode step, then throttle or defer persistence writes. Success is no probe below −10% while a capture is in flight.
2. An intermittent ~10 s entry dead zone. A request enters, both ranks freeze at 100% GPU for ~10 s, then prefill proceeds normally; it is non-deterministic and sometimes absent. The candidate region is the L1 capture/commit path once the pool is full (`snapshot action=skipped reason=byte_capacity`, 124 MB reserved, zero capture_evicts all day). It needs the capture path instrumented in a maintenance window. This is the same shape as the "prefill is only 131 t/s" complaint.

## 500K arithmetic

89.7 GB fixed + 0.344 GB/session + 12.3 KB/token. Six at 204800 = 106.4 GB observed; two at 500000 = 102.4 GB and 28.8 t/s on an older build; three at 500000 = 109 GB, against a measured 111 GB wall (an earlier three-session load was OOM-killed); six at 500000 = 128.6 GB, impossible. 500K exists with two sessions, not six.

The 500K needle has not been run. Cold prefill is 45–50 minutes by linear extrapolation; the continuation cache is what makes it usable after the first turn. The only cold-prefill lever left is the deep-attention rewrite (≤124 VGPR, 1.3–1.6×, research-grade); the dense Q4_0 → Q8_0 WMMA path is worth ~7% and is not decisive.

---

The pair is stopped. Nothing in this review changes production; it is the map for the next window.
