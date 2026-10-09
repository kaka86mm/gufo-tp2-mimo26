#!/bin/bash
# start-tp2-mimo.sh — bring up MiMo-V2.6-Flash-RL as a TP2 pair over usb4_rdma.
# rank0 runs on this host (it runs the bootstrap listener); rank1 is started
# over ssh with the same flags. All site-specific values come from run/env.sh.
# CAUTION: this script stops whatever else is serving from these two hosts
# (bare ranks and single-node containers) — run it in a maintenance window.
set -e

# Repo root (this file lives in run/). env.sh is the documented parameter block:
# it only sets defaults, so sourcing it never overrides what is already set, and
# it is absent when restore-prod.sh stages this file to /tmp.
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[ -f "$REPO/run/env.sh" ] && . "$REPO/run/env.sh"

# Logs live under $HOME/logs so they survive reboots; /tmp names stay
# as symlinks because the supervisor and the gate scripts grep those paths.
LOGDIR=${MIMO_LOG_DIR:-$HOME/logs}
mkdir -p "$LOGDIR"
# keep the legacy /tmp names resolving to the persistent logs
ln -sf "$LOGDIR/mimo-rank0.log" /tmp/mimo-rank0.log
ln -sf "$LOGDIR/mimo-rank1.log" /tmp/mimo-rank1.log

RANK1=${RANK1:-matri@192.168.110.44}
RANK0_IP=${RANK0_IP:-192.168.110.228}
# TP control-plane shared secret: both ranks must pass the same value, and it is
# the only thing guarding the control port. change-me-shared-secret is a
# placeholder — set TOKEN (documented in run/env.sh).
TOKEN=${TOKEN:-change-me-shared-secret}
MODEL=${MODEL:-/home/matri/models/mimo26-flash-rl/MiMo-V2.6-Flash-RL-MXFP4-00001-of-00002.gguf}
MTP=${MTP:-/home/matri/models/mimo26-flash-rl/mtp-MiMo-V2.6-Flash-RL-Q8_0.gguf}
# dense-sidecar graft (GUFO_MIMO_DENSE_SC below), the same path on both ranks.
DENSE_SIDECAR=${DENSE_SIDECAR:-/home/matri/models/mimo26-flash-rl/dense-full-q4_0.gguf}
BIN=${BIN:-/home/matri/gufo-mimo2-bin}
# The L2 disk cache sits in a different place per rank (see run/env.sh); both
# must be real directories.
CACHE_DIR_R0=${CACHE_DIR_R0:-$HOME/cache-disk}
CACHE_DIR_R1=${CACHE_DIR_R1:-/mnt/data1t/cache-disk}
SESSIONS=${SESSIONS:-6}
CONTEXT=${CONTEXT:-204800}
# L2 disk cap: six 256K sessions write a ~3.6-4.0 GB snapshot each
# (~24 GB total) plus staging headroom -> 28 GiB.
DISK_BYTES=${DISK_BYTES:-30064771072}
# L1 RAM snapshot pool: cap it explicitly. The auto rule ("half of free RAM,
# <=32 GiB") is evaluated when the weights have not been touched yet and can
# reserve far more than the pool will ever hold; engine VM plus a big pool is
# what lets the kernel OOM-kill unrelated daemons on a 128 GB box.
RAM_BYTES=${RAM_BYTES:-1073741824}
# rank1 keeps its L2 on a data disk: its root filesystem is too small, and the
# engine refuses a symlinked cache dir ("TP disk cache directory: Not a
# directory"), so this must be the real path. $HOME/cache-disk stays as a
# symlink there for operators only.
# Staging is a cap, not a reservation: a 200K prefix snapshots ~2.6 GB per
# rank, and a 256 MiB cap silently refused every snapshot past ~20K tokens
# (the L2 looked dead: no new .kvc after any big request).
STAGE_BYTES=${STAGE_BYTES:-3221225472}

[ -x "$BIN" ] || { echo "!! $BIN missing (build the engine and copy it to this path on both hosts)"; exit 1; }
ls /sys/class/infiniband/ 2>/dev/null | grep -q usb4_rdma || { echo "!! no usb4_rdma rails on rank0"; exit 1; }
ssh -o BatchMode=yes $RANK1 "[ -x $BIN ] || { echo '!! rank1 binary missing'; exit 1; }"

echo "== stopping TP2 production ranks (bare processes) =="
pkill -f 'gufo-.*serve.*--tp-ran[k]' 2>/dev/null || true
ssh -o BatchMode=yes $RANK1 "pkill -f 'gufo-.*serve.*--tp-ran[k]'" 2>/dev/null || true
sleep 3
echo "== stopping single-node production containers =="
docker stop gufo >/dev/null 2>&1 || true
ssh -o BatchMode=yes $RANK1 'docker stop gufo-u >/dev/null 2>&1 || true'
# Anchor the liveness check on the binary path: an unrelated command line that
# merely contains "gufo-...serve" must not look like a live rank (that blocked
# a production restore on 2026-10-08: the start aborted, service stayed down).
pgrep -f '^/home/matri/gufo-mimo2-bin serve' >/dev/null && { echo "!! rank0 still alive"; pgrep -af '^/home/matri/gufo-mimo2-bin serve'; exit 1; }

rm -f $LOGDIR/mimo-rank0.log $LOGDIR/mimo-rank1.log

echo "== rank0 =="
setsid nohup env GUFO_NO_GRAPH=1 GUFO_MIMO_DENSE_SC=$DENSE_SIDECAR GPU_MAX_HW_QUEUES=1 GUFO_AR_F16=1 HIP_VISIBLE_DEVICES=0 LD_LIBRARY_PATH=/opt/rocm-7.2.4/lib:/home/matri/gufo-libs \
  $BIN serve llm \
  --model "$MODEL" \
  --speculative mtp --mtp-model "$MTP" \
  --tp-world-size 2 --tp-rank 0 \
  --tp-bootstrap-port 18525 --tp-control-port 18526 --tp-control-token "$TOKEN" \
  --tp-rdma-device usb4_rdma0 \
  --host 0.0.0.0 --port 8080 \
  --max-pending-per-client 16 --prefill-chunk 64 --sessions $SESSIONS --context $CONTEXT \
  --cache-disk $CACHE_DIR_R0 --cache-disk-bytes $DISK_BYTES \
  --cache-ram-bytes $RAM_BYTES \
  --cache-disk-staging-bytes $STAGE_BYTES \
  > $LOGDIR/mimo-rank0.log 2>&1 < /dev/null &

for i in $(seq 1 15); do
  sleep 1
  ss -tln | grep -q 18525 && { echo "rank0 bootstrap port up"; break; }
done
ss -tln | grep -q 18525 || { echo "!! rank0 bootstrap port never came up:"; tail -20 $LOGDIR/mimo-rank0.log; exit 1; }

echo "== rank1 ($RANK1) =="
ssh -o BatchMode=yes $RANK1 "sg render -c 'mkdir -p "$LOGDIR"; setsid nohup env GUFO_NO_GRAPH=1 GUFO_MIMO_DENSE_SC=$DENSE_SIDECAR GPU_MAX_HW_QUEUES=1 GUFO_AR_F16=1 HIP_VISIBLE_DEVICES=0 LD_LIBRARY_PATH=/opt/rocm-7.2.4/lib:/home/matri/gufo-libs \
  $BIN serve llm \
  --model $MODEL \
  --speculative mtp --mtp-model $MTP \
  --tp-world-size 2 --tp-rank 1 \
  --tp-bootstrap-host $RANK0_IP \
  --tp-bootstrap-port 18525 --tp-control-port 18526 --tp-control-token \"$TOKEN\" \
  --tp-rdma-device usb4_rdma0 \
  --host 0.0.0.0 --port 8081 \
  --max-pending-per-client 16 --prefill-chunk 64 --sessions $SESSIONS --context $CONTEXT \
  --cache-disk $CACHE_DIR_R1 --cache-disk-bytes $DISK_BYTES \
  --cache-ram-bytes $RAM_BYTES \
  --cache-disk-staging-bytes $STAGE_BYTES \
  > $LOGDIR/mimo-rank1.log 2>&1 < /dev/null'"

echo "== waiting for RDMA handshake / model load =="
for i in $(seq 1 120); do
  sleep 3
  grep -q "rdma_ready" $LOGDIR/mimo-rank0.log 2>/dev/null && { echo "RDMA READY on rank0"; break; }
  grep -qiE "error|fatal" $LOGDIR/mimo-rank0.log 2>/dev/null && { echo "RANK0 ERROR:"; tail -10 $LOGDIR/mimo-rank0.log; exit 1; }
done
grep -q rdma_ready $LOGDIR/mimo-rank0.log || { echo "!! RDMA never became ready"; tail -10 $LOGDIR/mimo-rank0.log; exit 1; }
echo "== up: rank0 :8080 (rank1 :8081). logs: /tmp/mimo-rank{0,1}.log =="
echo "== rollback: stop both ranks, start the previous serving stack (deploy/mimo-stop.sh), then relaunch this script =="
