# Pitfalls

Everything that bit me, so it doesn't bite you. Other documents reference these by number, so the numbering is fixed. Most of these cost me an outage, or a measurement I believed for days.

**1. A symlinked cache directory fails the whole load and takes the pair down.**
rank1's cache has to live on the data disk (28 GiB of snapshots against a nearly full root filesystem), so the obvious move is to point `--cache-disk` at a symlink. The engine refuses it: `Error loading model '<path>': TP disk cache directory: Not a directory`, rank1 dies, and rank0 follows right behind with `tp_pair_lost`. A directory-layout problem that presents as a transport failure. Pass the real directory to the engine and keep the symlink only as a waypoint for yourself. Nothing else about the path is checked.

**2. `--cache-disk-staging-bytes` is a cap, not a reservation.**
The flag bounds how much RAM one queued snapshot may occupy and how much one disk read may occupy. A snapshot bigger than the cap is dropped with no error at all. The symptom is that the directory just stops growing and requests report `usage.gufo.cache_miss_reason = "no_checkpoint"`, which reads like "this prefix has no checkpoint" instead of "your snapshot was refused". I shipped 256 MiB for a while and believed the disk cache worked; it was dead for every prefix over ~20K tokens. A full 200K prefix snapshots about 2.6 GB per rank, so the cap here is 3 GiB. Watch `usage.gufo.cache_disk_queued_bytes` / `cache_disk_enqueue_ms` and count the files, because nothing else will tell you.

**3. `--cache-ram-bytes` defaults to half of free RAM, up to 32 GiB. Pin it.**
The default is evaluated at engine start, when "free RAM" is measured on a host whose page cache has not been filled by the weights yet. On a box where 6 GB of headroom is the whole margin, that auto-size is a hazard, not a convenience. Set it explicitly (1 GiB here). The pool only holds a couple of snapshots anyway; the disk cache is what carries continuation.

**4. A snapshot needs time to commit. The file appearing is not the snapshot being usable.**
You watch the snapshot land, kill the engine seconds later, restart, and the prefix misses with `cache_miss_reason=no_checkpoint` (and the file gets pruned at the next start). Write completion is not the commit step the next process needs. Give a freshly written large snapshot about two minutes of idle before restarting. Measured both ways on the 193K prefix: killed seconds after the write, miss; written, 120 s idle, then restart, `cached_tokens=192910` and a 3.76 s restore. That is the difference between a 692 s cold prefill and 7.8 s.

**5. `no_checkpoint` can mean "never written", not "no checkpoint".**
The reason code only says no usable checkpoint was found; it does not distinguish "never captured", "refused at staging" (#2), "written but not committed" (#4), or "a checkpoint that should have landed never did". The last case is real: a capture path returned non-blocking and the caller erased the checkpoint unconditionally, so the previous snapshot was permanently lost. It showed up in 1 of 5 continuation attempts, each costing a 1,415-token re-prefill (4.9 s). After making the capture wait, three consecutive trials all reported `prefill_tokens=0` and cold prefill was unchanged (121.4 s). When debugging this: check the staging cap and the commit window first, then look for a lost capture. The code tells you which prefix was considered, not why the snapshot is absent.

**6. `event=listening` is not readiness, and `/health` is not liveness.**
The launcher prints `listening` and returns "success"; clients then get errors. Worse, rank0 answers `/health` with 200 for about a minute after its peer has died, so a restore can report success with rank1 gone. `event=listening` is emitted before the KV for a large context is allocated. Readiness is `/health` returning 200 **and** the peer's engine process being alive on the other host, which is what `deploy/restore-prod.sh` waits for. A restore that reports failure is better than one that reports success with half a pair. Related default worth knowing: `--prefill-chunk 512` makes a 20K prefill run at 329 tok/s and stalls other sessions' decode for up to 2.3 s between tokens, where `64` gives 394 tok/s and 1.07 s stalls. It is a concurrency knob, not a prefill-throughput knob; I run 64.

**7. SIGTERM is not enough for an engine stuck in an uninterruptible GPU wait.**
You stop the pair; the process is still there minutes later holding ~110 GB of GTT. The next load starts with ~12 GB free, the kernel OOMs it, the supervisor tries to restore again, and it cascades. A rank in an uninterruptible GPU wait does not take SIGTERM, and its pinned memory is invisible to the OOM killer's process table, so nothing reclaims it. Give SIGTERM a bounded wait, then escalate to SIGKILL (as `mimo-stop.sh` and `restore-prod.sh` do), verify the process is gone by binary path, and only then start the next load.

**8. Replacing the binary while a rank winds down fails with ETXTBSY, even though `pgrep` sees nothing.**
`scp: dest open "<...>/gufo-mimo2-bin": Failure` (text file busy) during a deploy that pgrep says is safe. Right after a SIGKILL the old process still maps the binary for a moment while it exits; the inode is busy but the process is invisible to `pgrep` (its cmdline can even read empty). Copy to `$BIN.new` and `mv -f`: rename(2) is immune to the busy inode. Do it on both hosts. This cost me about four minutes of downtime; the supervisor's retry recovered the pair by itself a few minutes later.

**9. `flock` file descriptors are inherited by the engine.**
After a restore, every later restore, including the supervisor's automatic one, fails with `another restore is already in flight`, with no restore running. The script takes the lock with `exec 9>/tmp/mimo-restore.lock`; every child it starts inherits fd 9, and the engine holds it for life, so the exclusive lock is never released. Close the descriptor before launching long-lived children (`... 9>&- ...`). Check with `ls -l /proc/<engine-pid>/fd` if you ever doubt it.

**10. Two restores can want the same pair at once.**
A manual restore and the supervisor's auto-restore overlap; each `pkill` kills the other's half; the pair ends up down. Take an exclusive `flock` for the whole restore, and only release the shared marker (`/tmp/mimo-no-supervise`) if this run created it. A script must not end a test window it did not open.

**11. A restore stuck in its readiness poll holds the lock indefinitely.**
After a link flap, every restore says `another restore is already in flight`; a stray restore process is polling a rank that already `load_failed`. The poll's `ssh` calls had no connect timeout, so one dead link hangs the poll, and the poll still holds the `flock`. `-o BatchMode=yes -o ConnectTimeout=5` on every ssh in the restore path; if it has already happened, kill the stray process to recover.

**12. The GTT guard threshold has to sit above steady state, with real margin.**
The supervisor killed a healthy pair during a maintenance window: the guard was 112 GB while steady state was ~110 GB, a 2 GB margin that a normal transient during load or deploy exceeds, so it fired on the wrong thing. It is 118 GB now. The guard itself is not optional: pinned GTT is invisible to the OOM killer, so polling `mem_info_gtt_used` and killing the engines is the only protection that works (#7).

**13. The supervisor's restore path must carry the same configuration as the launcher.**
You change a flag (say `--context`) in the start script, and one supervisor tick later it silently reverts: the pair comes back with the old values. The restore path has its own copy of the launch parameters (`SESSIONS` / `CONTEXT` / RAM / staging / disk sizes), and the supervisor's automatic restore goes through it. Keep one source for the parameter block, sourced by both the launcher and `restore-prod.sh`, and make the restore path take environment overrides too. Until that is true, changing a knob means changing both places.

**14. The two hosts can be on different clocks.**
Correlating logs across ranks shows rank1's timestamps eight hours "stale" (a request that clearly ran at 13:40 appears at 05:40) and you conclude rank1 never started at all. One host was on UTC. Set both hosts to the same timezone before doing cross-rank log forensics; if you can't, convert every timestamp before believing an event order. This one cost me twenty minutes of misdiagnosis.

**15. HTTP rejects bodies above ~8 MB with 413 `payload_too_large`.**
A large prompt returns HTTP 413 with error type `payload_too_large` before any inference happens. A 200K-token prompt body is only about 1 MB of JSON, so the cap doesn't constrain normal long-context work. It bites when prompts are inflated (attachments, base64, huge segment counts) or when a script expands a prompt past what it planned.

**16. Measuring concurrency: cohorts queue behind resident sessions.**
A "mixed six-way" taken right after another six-way cohort reads **21 t/s**; taken right after the 58.7K cold prefill it reads **15.8 t/s**; the real figure is **55.0 t/s**. The previous cohort's sessions are still resident and draining, so the client wall measures queue time, not decode. Drain between cohorts (the batteries sleep ~20 s and then confirm the six slots are free), and order the run so mixed cohorts are measured **before** the large prefills, never after. A concurrency number without a drain in front of it is not a decode number.

**17. The tokenizer's segment ratio: never predict prompt length from segment count.**
A prompt intended as ~176K tokens is rejected with `context_length_exceeded`; a script predicts 54K tokens for 5,430 segments and the engine counts 58.7K. The `第%s章...` filler measures **11.736 tokens per segment** with 4-digit indices (the engine counted 492,914 tokens for 42,000 segments), but the ratio moves with the template and the index width: 11.7 to 16.3 across the templates I used here. One early helper printed `approx_tokens = segments × 1.43`, an ~8x underestimate, which is how a 15,000-segment rung turned into a 243,910-token request. Read `usage.prompt_tokens` from a real response (or the engine log) and calibrate the ratio per template; keep a margin under the window and treat the engine's `context_length_exceeded` rejection as the guardrail it is.