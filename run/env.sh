#!/bin/bash
# env.sh — the launcher's parameter block: every site-specific knob of the TP2
# deployment with the value we run in production. run/start-tp2-mimo.sh sources
# this file if it exists, and every line is written as ${VAR:-default}, so this
# file documents rather than forces: anything already exported wins, e.g.
#
#   SESSIONS=6 CONTEXT=204800 ./run/start-tp2-mimo.sh
#
# Edit the hosts, the token, the model paths and (if your two hosts differ) the
# cache directories. Each flag and the trap behind it: docs/CONFIGURATION.md.
#
# Not here: the engine's own environment (GUFO_NO_GRAPH, GUFO_MIMO_DENSE_SC is
# DENSE_SIDECAR below, GPU_MAX_HW_QUEUES=1, GUFO_AR_F16, HIP_VISIBLE_DEVICES,
# LD_LIBRARY_PATH). Those are baked into the launcher's env prefix on both ranks.

# ----------------------------------------------------------------- the pair ---
# rank0 is the host you launch from (it runs the bootstrap listener); rank1 is
# dialled over ssh. rank1 dials back to RANK0_IP for the rendezvous.
: "${RANK1:=matri@192.168.110.44}"     # ssh target of the peer (needs BatchMode keys)
: "${RANK0_IP:=192.168.110.228}"       # this host as the peer sees it (--tp-bootstrap-host)
: "${SSH_USER:=matri}"                 # login user inside every ssh/scp target: RANK1 here,
                                       # PEER in deploy/mimo-supervisor.sh, and the calls in
                                       # deploy/restore-prod.sh, deploy/mimo-stop.sh and
                                       # run/bench/l2-cache-test.sh (each spells it out)

# ---------------------------------------------------------------- the token ---
# --tp-control-token: the shared secret of the TP control port. It must be
# identical on both ranks — it is the only thing guarding that port, so treat it
# as a credential. change-me-shared-secret is a placeholder: change it on both
# hosts before the control port is reachable from anywhere you do not own.
: "${TOKEN:=change-me-shared-secret}"

# ------------------------------------------------------------------- models ---
# Identical absolute paths on both hosts (the launcher passes them to rank1
# verbatim over ssh).
: "${MODEL:=/home/matri/models/mimo26-flash-rl/MiMo-V2.6-Flash-RL-MXFP4-00001-of-00002.gguf}"
: "${MTP:=/home/matri/models/mimo26-flash-rl/mtp-MiMo-V2.6-Flash-RL-Q8_0.gguf}"
# 4-bit dense sidecar (the graft target of the dense-sidecar optimisation: dense
# weights 6,583 MB -> 3,485 MB at load), passed as GUFO_MIMO_DENSE_SC. Without
# the file, drop that assignment from the launcher's env prefix — the engine
# runs fine without the sidecar.
: "${DENSE_SIDECAR:=/home/matri/models/mimo26-flash-rl/dense-full-q4_0.gguf}"

# ------------------------------------------------------------------- binary ---
: "${BIN:=/home/matri/gufo-mimo2-bin}"        # engine binary, same path on both hosts
: "${KEEP_BIN:=$HOME/gufo-mimo2-bin.splitk}"  # pinned rollback copy that deploy/restore-prod.sh
                                              # puts back; its KEEP= line spells this path out
                                              # (keep the two in sync when you promote a build)

# ------------------------------------------------------------------ serving ---
: "${SESSIONS:=6}"              # concurrent sequences, each with its own full KV allocation
: "${CONTEXT:=204800}"          # per-session window in tokens; sessions x context is the memory
                                # bill (see "Sizing the context" in docs/CONFIGURATION.md)
: "${DISK_BYTES:=30064771072}"  # L2 disk cap, 28 GiB (LRU inside): six ~4 GB snapshots plus staging
: "${RAM_BYTES:=1073741824}"    # L1 in-RAM snapshot pool, 1 GiB — pin it, the auto rule ("half of
                                # free RAM, <=32 GiB") reserves far too much when it is evaluated
                                # while the weights are still untouched
: "${STAGE_BYTES:=3221225472}"  # snapshot staging, 3 GiB — a CAP, not a reservation: it bounds one
                                # queued snapshot and one disk read, and below the size of the
                                # snapshots you want the disk cache dies silently
                                # (cache_miss_reason=no_checkpoint). A 200K prefix is ~2.6 GB.

# --------------------------------------------------------------- disk cache ---
# One L2 directory per rank, both REAL directories: a symlinked cache dir fails
# the load outright ("TP disk cache directory: Not a directory") and takes the
# peer down with tp_pair_lost — see docs/PITFALLS.md. rank1 has no room on its
# root filesystem, so its cache lives on the data disk; the $HOME symlink kept
# there is for operators only, the engine never sees it.
: "${CACHE_DIR_R0:=$HOME/cache-disk}"        # rank0: root filesystem has room
: "${CACHE_DIR_R1:=/mnt/data1t/cache-disk}"  # rank1: data disk, real path

# --------------------------------------------------------------------- logs ---
# Persistent log directory on each rank. /tmp/mimo-rank{0,1}.log stay symlinks to
# it because the supervisor and the bench scripts grep those names.
: "${MIMO_LOG_DIR:=$HOME/logs}"