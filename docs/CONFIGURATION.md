# Configuration

Every flag the launcher passes, what I run, what the engine defaults to, and the trap behind it. Values are for MiMo-V2.6-Flash-RL (MXFP4 trunk + Q8_0 MTP draft) on two 128 GB Strix Halo hosts.

The knobs live in `run/env.sh` (sourced by `run/start-tp2-mimo.sh`), except the supervisor's, which is the systemd unit's argument. Anything not set falls back to the engine's own default.

## Launcher flags

| flag | value here | engine default | notes |
|---|---|---|---|
| `--model` | `…/MiMo-V2.6-Flash-RL-MXFP4-00001-of-00002.gguf` | — | first shard of a 2-shard MXFP4 trunk; identical paths on both ranks |
| `--speculative` / `--mtp-model` | `mtp` / `…/mtp-MiMo-V2.6-Flash-RL-Q8_0.gguf` | off | MTP draft head, `draft_limit=7` in the log |
| `--tp-world-size` / `--tp-rank` | `2` / `0` here, `1` on the peer | 1 | TP2 over the RDMA rails; rank1 dials back to rank0's bootstrap |
| `--tp-bootstrap-port` / `--tp-control-port` | `18525` / `18526` | — | rendezvous and control plane (plain TCP) |
| `--tp-control-token` | *shared secret* | — | must be identical on both ranks. Treat it as a password: it is the only thing guarding the control port. |
| `--tp-rdma-device` | `usb4_rdma0` | — | the RoCE device from [gufo-tp2-tb4-rdma](https://github.com/kaka86mm/gufo-tp2-tb4-rdma) |
| `--host` / `--port` | `0.0.0.0` / `8080` (rank0), `8081` (rank1) | — | clients talk to rank0; rank1's port is for diagnostics |
| `--max-pending-per-client` | `16` | 1 | queue depth per client before the HTTP layer pushes back |
| `--prefill-chunk` | `64` | — | tokens per prefill step. Smaller means less burst pressure on other sessions' decode, more steps. It is a concurrency knob, not a prefill-speed knob. |
| `--sessions` | `6` | 1 | concurrent sequences, each with its own full KV allocation. sessions x context is the memory bill. |
| `--context` | `204800` | model default | per-session window; see "Sizing the context" |
| `--cache-disk` | rank0 `$HOME/cache-disk`, rank1 `/mnt/data1t/cache-disk` | disabled | the L2 disk cache; see below |
| `--cache-disk-bytes` | `30064771072` (28 GiB) | 8 GiB | cap on the whole directory (LRU inside it) |
| `--cache-disk-staging-bytes` | `3221225472` (3 GiB) | auto: at most 1 GiB and 1/8 of free RAM | RAM cap for one queued snapshot and for each disk read. A cap, not a reservation. |
| `--cache-ram-bytes` | `1073741824` (1 GiB) | auto: half of free RAM, up to 32 GiB | the L1 in-RAM snapshot pool. Set it explicitly. |

## Environment

| variable | value | why |
|---|---|---|
| `GUFO_MIMO_DENSE_SC` | `…/dense-full-q4_0.gguf` | grafts the q4_0 dense sidecar at load: dense weights 6,583 MB → 3,485 MB. The file must be on both hosts. |
| `GPU_MAX_HW_QUEUES=1` | `1` | without it the engine sits at 100% "busy" on the GPU queues and burns ~28 W doing nothing |
| `GUFO_AR_F16=1` | on | fp16 all-reduce for the TP exchange |
| `GUFO_ATTN_SHARED` | on; set `0` to disable | shared-KV decode attention: the 16 query heads of a KV head reuse staged rows through LDS (+48% at 65K depth). Default-on in the binary; the switch exists so it stays falsifiable. |
| `GUFO_NO_GRAPH=1` | `1` | graph capture off for this deployment |
| `HIP_VISIBLE_DEVICES=0` | `0` | the iGPU |
| `LD_LIBRARY_PATH` | `/opt/rocm-7.2.4/lib:$HOME/gufo-libs` | ROCm plus the extra libraries (the thunderbolt-ibverbs provider lives here) |

## The disk cache

**Where it is.** One plain directory per rank, passed as `--cache-disk`. I run:

- rank0: `$HOME/cache-disk`. That host's root filesystem has room.
- rank1: `/mnt/data1t/cache-disk`. Its root filesystem does not (28 GiB of snapshots against a nearly full NVMe), so the cache goes on the data disk. `$HOME/cache-disk` exists there too, but only as a symlink for me to find it by hand. The engine never sees that path.

**Three requirements**, each of which cost me real downtime:

1. It must exist and be writable by the user the engine runs as.
2. It must be a real directory. A symlinked cache directory fails the load outright: `Error loading model '…': TP disk cache directory: Not a directory`, the rank dies, and the other rank follows with `tp_pair_lost`. That is why rank1 does not just symlink it.
3. It must be big enough for the snapshots you actually want to keep. Past `--cache-disk-bytes` the cache's own LRU silently evicts.

**How big snapshots are.** A snapshot is the KV of a whole prefix at a checkpoint: roughly `context x 12.3 KB` per rank. Measured here: 68,911 tokens → 984 MB; 141,513 → 2.0 GB; 192,910 → 2.73 GB. Six 200K sessions want roughly 17-24 GB, plus headroom for the staging copy and for a second snapshot of the same session while it grows. That is where 28 GiB comes from.

**Staging is a cap, not a reservation.** `--cache-disk-staging-bytes` bounds two things: how much RAM one queued snapshot may occupy while it is being written, and how much one disk read may occupy while restoring. Set it below the size of the snapshots you care about and nothing errors. The directory just stops growing and requests report `usage.gufo.cache_miss_reason = "no_checkpoint"`, which reads like "this prefix has no checkpoint" rather than "your snapshot was refused". I ran 256 MiB for a while and believed the disk cache was working; it was dead for every prefix over ~20K tokens. 3 GiB covers a full 200K prefix.

**Snapshots need a moment to commit.** The file showing up in the directory is not the same as the snapshot being usable. Kill the engine within seconds of the write and the next start will not recognise it, and prunes it. After a large request, leave about two minutes of idle before restarting. That is the difference between a 692 s cold prefill and a 3.8 s restore.

**Per rank, not shared.** Each rank keeps its own snapshots, with different file naming (rank0 writes `<prefix>-<suffix>.kvc`, rank1 writes `tp2-<hash>.snap`). Nothing needs to be copied between hosts.

**Checking on it.** `du -sh <dir>`, and `ls -la <dir> | sort -k5 -n | tail` for the biggest snapshots. Per-request truth is in the response's `usage.gufo` block (`cache_hit`, `cache_miss_reason`, `cache_common_prefix_tokens`, `prompt_tokens_details.cached_tokens`, `prefill_tokens`, `cache_restore_ms`) and in the engine log line.

## Sizing the context

The context is not a preference, it is an equation. Measured across the deployment:

```
GTT ≈ 89.7 GB fixed (weights + workspace + MTP)
    + Σ sessions (344 MB + context × 12.3 KB)   per rank
```

Real anchors: five sessions at 256K load at 107,507 MB of GTT and run. Six at 256K need about 111 GB and fail: the allocation dies at ~109.7 GB on the board with 2.25 GiB less usable RAM, and the smaller board is the one that binds. Six at 200K land at 106,397 MB measured, about 1 GB below the 5x256K working point, 6.3 GB of free memory left at the worst moment of a full test.

So: pick the session count you need, subtract the 89.7 GB, and back-solve the context with about 3 GB of margin. If you want 6x256K you need more RAM, not a different flag.

## The supervisor

`deploy/mimo-supervisor.service` runs `mimo-supervisor.sh <GTT_LIMIT_GB>`; I pass 118. It polls every 20 seconds and:

- kills both ranks if `mem_info_gtt_used` (summed over the DRM devices) goes past the limit. The GPU's pinned pages are invisible to the OOM killer, so this is the only guard that works.
- kills the local rank if the peer is unreachable; a rank whose peer vanished would otherwise spin forever.
- when the pair is down but the peer answers, runs `deploy/restore-prod.sh` and then `warmup.sh`.

The limit has to sit above the steady state (106.4 GB here) and below what the host can survive. At 112 GB it was only 2 GB above steady state and a maintenance window tripped it, so it is 118 now. The marker file `/tmp/mimo-no-supervise` suspends all of the above; my deploy and test windows hold it, and `restore-prod.sh` only releases a marker it created itself.