# Configuration reference

Everything the launcher passes, what it means, what we run, what the default is, and the trap behind it. Values are for MiMo-V2.6-Flash-RL (MXFP4 trunk + Q8_0 MTP draft) on two 128 GB Strix Halo hosts.

The knobs live in `run/env.sh` (sourced by `run/start-tp2-mimo.sh`) or, for the supervisor, in the systemd unit's argument. Anything not set falls back to the engine's own default.

## The launcher

| flag | value here | engine default | notes |
|---|---|---|---|
| `--model` | `…/MiMo-V2.6-Flash-RL-MXFP4-00001-of-00002.gguf` | — | the first shard of a 2-shard MXFP4 trunk; both ranks need identical paths |
| `--speculative` / `--mtp-model` | `mtp` / `…/mtp-MiMo-V2.6-Flash-RL-Q8_0.gguf` | off | MTP draft head, `draft_limit=7` in the log |
| `--tp-world-size` / `--tp-rank` | `2` / `0` on this host, `1` on the peer | 1 | TP2 over the RDMA rails; rank1 connects back to rank0's bootstrap |
| `--tp-bootstrap-port` / `--tp-control-port` | `18525` / `18526` | — | rendezvous and control plane (TCP over the management network) |
| `--tp-control-token` | *shared secret* | — | **must be identical on both ranks**; treat it as a password — it is the only thing guarding the control port |
| `--tp-rdma-device` | `usb4_rdma0` | — | the RoCE device from [gufo-tp2-tb4-rdma](https://github.com/kaka86mm/gufo-tp2-tb4-rdma) |
| `--host` / `--port` | `0.0.0.0` / `8080` (rank0), `8081` (rank1) | — | clients talk to rank0; rank1's port is for diagnostics |
| `--max-pending-per-client` | `16` | 1 | queue depth per client before the HTTP layer pushes back |
| `--prefill-chunk` | `64` | — | tokens per prefill step; smaller = less burst pressure, more steps |
| `--sessions` | **`6`** | 1 | concurrent sequences, **each with its own full KV allocation** — this × `--context` is the memory bill |
| `--context` | **`204800`** | model default | per-session window; see "Sizing the context" below |
| `--cache-disk` | **rank0 `$HOME/cache-disk`, rank1 `/mnt/data1t/cache-disk`** | disabled | the L2 disk continuation cache — see "The disk cache" below |
| `--cache-disk-bytes` | **`30064771072`** (28 GiB) | 8 GiB | cap on the whole directory (LRU inside it) |
| `--cache-disk-staging-bytes` | **`3221225472`** (3 GiB) | auto: ≤1 GiB and 1/8 of free RAM | RAM cap **for one queued snapshot and for each disk read** — a cap, not a reservation; see the trap below |
| `--cache-ram-bytes` | **`1073741824`** (1 GiB) | auto: half of free RAM, at most 32 GiB | the L1 in-RAM snapshot pool; pin it explicitly |

## The environment

| variable | value | why |
|---|---|---|
| `GUFO_MIMO_DENSE_SC` | `…/dense-full-q4_0.gguf` | grafts a 4-bit dense sidecar at load: dense weights 6,583 MB → 3,485 MB. Present on both hosts. |
| `GPU_MAX_HW_QUEUES=1` | `1` | without it the engine idles at 100% "busy" on the GPU queues and burns ~28 W doing nothing |
| `GUFO_AR_F16=1` | on | fp16 all-reduce for the TP exchange |
| `GUFO_ATTN_SHARED` | on by default (set `0` to disable) | shared-KV decode attention: the 16 query heads of a KV head reuse staged rows through LDS (+48% at 65K depth). Default-on in the shipped binary; the escape hatch exists because it is the kind of optimisation that must be falsifiable. |
| `GUFO_NO_GRAPH=1` | `1` | disables graph capture for this deployment |
| `HIP_VISIBLE_DEVICES=0` | `0` | the iGPU |
| `LD_LIBRARY_PATH` | `/opt/rocm-7.2.4/lib:$HOME/gufo-libs` | ROCm plus the extra libraries (the thunderbolt-ibverbs provider lands here) |

## The disk cache

**Where it lives.** It is a plain directory per rank, passed as `--cache-disk`. We run:

- **rank0 `$HOME/cache-disk`** — the root filesystem on that host has room.
- **rank1 `/mnt/data1t/cache-disk`** — that host's root filesystem does not (28 GiB of snapshots against a nearly full NVMe), so its cache lives on the data disk. `$HOME/cache-disk` is kept as a **symlink** to it *for humans only*: an operator looking there finds the data, and the engine never sees that path.

**Three hard requirements**, each of which cost us a production incident:

1. It must exist and be writable by the user the engine runs as.
2. It must be a **real directory**. A symlinked cache directory fails the load outright: `Error loading model '…': TP disk cache directory: Not a directory`, the rank dies, and the other rank follows it down with `tp_pair_lost`. This is why rank1 does not simply symlink `$HOME/cache-disk`.
3. It must be big enough for the snapshots you actually want to keep — see the sizing below — because the cache's own LRU silently evicts once the directory hits `--cache-disk-bytes`.

**How big is a snapshot.** A snapshot is the KV of a whole prefix at a checkpoint: roughly `context × 12.3 KB` per rank. Measured on this deployment: 68,911 tokens → 984 MB; 141,513 → 2.0 GB; 192,910 → 2.73 GB. Six 200K sessions therefore want ~17–24 GB, plus headroom for the staging copy and for a second snapshot of the same session as it grows — hence 28 GiB.

**`--cache-disk-staging-bytes` is a cap, not a reservation.** It bounds (a) how much RAM one *queued* snapshot may occupy while it is being written and (b) how much one disk *read* may occupy while it is being restored. Set it below the size of the snapshots you care about and nothing errors: the directory simply stops growing, and requests report `usage.gufo.cache_miss_reason = "no_checkpoint"`, which reads like "this prefix has no checkpoint" rather than "your snapshot was refused". We shipped 256 MiB for a while and believed the disk cache was working; it was dead for every prefix longer than ~20K tokens. 3 GiB covers a full 200K prefix.

**Snapshots need a moment to commit.** The file appearing in the directory is not the same as the snapshot being usable: kill the engine within seconds of the write and the next start will not recognise it (and prunes it). Leave roughly two minutes of idle after a large request before restarting — that is the difference between a 692 s cold prefill and a 3.8 s restore.

**Per rank, not shared.** Each rank keeps its own snapshots (the file naming differs by rank role — rank0 writes `<prefix>-<suffix>.kvc`, rank1 writes `tp2-<hash>.snap`). Nothing needs to be copied between hosts.

**Inspecting it.** `du -sh <dir>`, `ls -la <dir> | sort -k5 -n | tail` for the biggest snapshots, and per-request truth in the response's `usage.gufo` block: `cache_hit`, `cache_miss_reason`, `cache_common_prefix_tokens`, plus `prompt_tokens_details.cached_tokens`, `prefill_tokens` and `cache_restore_ms` in the engine log line.

## Sizing the context

The context is not a preference, it is an equation. Measured across the deployment: 

```
GTT ≈ 89.7 GB fixed (weights + workspace + MTP)
    + Σ sessions (344 MB + context × 12.3 KB)   per rank
```

Anchors from the real machines: five sessions at 256K load at **107,507 MB** of GTT and run; six at 256K need ~**111 GB** and fail — the allocation dies at ~**109.7 GB** on the board with 2.25 GiB less usable RAM (the two boards are not identical, and the smaller one is what binds). Six at 200K land at **106,397 MB measured**, ~1 GB below the 5×256K working point, leaving 6.3 GB of free memory at the worst moment of a full test.

So: pick the session count you need, subtract the 89.7 GB, and back-solve the context with ~3 GB of margin. If you want 6×256K you need the extra RAM, not a different flag.

## The supervisor

`deploy/mimo-supervisor.service` runs `mimo-supervisor.sh <GTT_LIMIT_GB>`; we pass **118**. It polls every 20 seconds and:

- kills both ranks if `mem_info_gtt_used` (summed over the DRM devices) exceeds the limit — the GPU's pinned pages are invisible to the OOM killer's process table, so this is the only guard that works;
- kills the local rank if the peer is unreachable (a rank whose peer vanished would otherwise spin);
- when the pair is down but the peer answers, runs `deploy/restore-prod.sh` and then `warmup.sh`.

The limit must sit **above the steady state** (106.4 GB here) and **below what the host can survive**: at 112 GB it was only 2 GB above steady and a maintenance window tripped it. The marker file `/tmp/mimo-no-supervise` suspends all of the above; deploy and test windows hold it, and `restore-prod.sh` only releases a marker it created itself.