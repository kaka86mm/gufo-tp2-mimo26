# Reproducing the deployment

There are two performance lines in this repo's history. Check which one you are
running before comparing numbers.

| line | engine source | measured binary | 1 stream, 1K | 6-way, 1K |
|---|---|---|---|---|
| **0.15.0 port (published)** | [gufo-mimo26](https://github.com/kaka86mm/gufo-mimo26) tag `mimo2-0.15.0` | `96e5afcc…` | 29.2–30.1 t/s | 85.5–86 t/s |
| 0.7.0 (the table in the README) | not part of this release | `85e789cf` | 34.7 t/s | 92.6 t/s |

The 0.15.0 port is the maintainable mainline: it is the tree published at
`gufo-mimo26`, and its full numbers are in [docs/REVIEW.md](docs/REVIEW.md).
The README table is the older 0.7.0 line; keep that in mind when comparing a
fresh build against it.

The rest of this file is the published 0.15.0 chain.

## 0. Hardware and transport

Two 128 GB Strix Halo boards (Ryzen AI MAX+ 395, gfx1151), Ubuntu 24.04, kernel
7.0.0-34, ROCm 7.2.4, two USB4 cables. Bring up the RDMA link first, following
[gufo-tp2-tb4-rdma](https://github.com/kaka86mm/gufo-tp2-tb4-rdma). Both hosts
must show `usb4_rdma0` and both links must train at 20.0 Gb/s ×2:

```sh
cat /sys/bus/thunderbolt/devices/*-*/rx_speed
ls /sys/class/infiniband/
```

The engine log reaches `event=rdma_ready` only after the pair handshakes; a
listening port is not readiness.

## 1. Engine

```sh
git clone https://github.com/kaka86mm/gufo-mimo26
cd gufo-mimo26
git checkout mimo2-0.15.0

# ROCm 7.2.4 at /opt/rocm-7.2.4, plus the gufo build dependencies
sudo apt install build-essential cmake ninja-build pkg-config \
  libicu-dev libcurl4-openssl-dev libssl-dev libpng-dev libjpeg-dev \
  libwebp-dev libsndfile1-dev libsoxr-dev libavformat-dev libavcodec-dev \
  libavutil-dev libswscale-dev ffmpeg libibverbs-dev \
  hipblas-dev hipblaslt-dev rocblas-dev hipcub-dev rocprim-dev rocwmma-dev

cmake --preset release -DGUFO_ENABLE_TP2_RDMA=ON -DGUFO_MIMO2_HIP=ON
cmake --build --preset release --parallel 8
./build/release/gufo diagnose
```

Both flags are required: `GUFO_MIMO2_HIP` defaults to OFF, and without it the link fails on every `mimo2` symbol. Copy `build/release/gufo` to `$HOME/gufo-mimo2-bin` on both hosts. The measured
production binary is md5 `96e5afcc8d56953f9984e6a4f4e6f79e` (303,330,824 B).
A rebuild in a different directory is not byte-identical — `RelWithDebInfo`
embeds source paths — but it is the same code. Keep a pinned copy on both hosts:

```sh
cp ~/gufo-mimo2-bin ~/gufo-mimo2-bin.port15
```

Copy the same file to both ranks and compare `md5sum`. A different binary on one
rank fails the TP handshake.

## 2. Model files

The trunk and the MTP draft are MIT-licensed and come from
[`ggml-org/MiMo-V2.6-Flash-RL-GGUF`](https://huggingface.co/ggml-org/MiMo-V2.6-Flash-RL-GGUF):

```sh
hf download ggml-org/MiMo-V2.6-Flash-RL-GGUF \
  --include "MiMo-V2.6-Flash-RL-MXFP4-0000*-of-00002.gguf" \
            "mtp-MiMo-V2.6-Flash-RL-Q8_0.gguf" \
            "mmproj-MiMo-V2.6-Flash-RL-BF16.gguf" \
  --local-dir ~/models/mimo26-flash-rl
```

| file | bytes |
|---|---:|
| `MiMo-V2.6-Flash-RL-MXFP4-00001-of-00002.gguf` | 5,948,640 |
| `MiMo-V2.6-Flash-RL-MXFP4-00002-of-00002.gguf` | 167,363,516,512 |
| `mtp-MiMo-V2.6-Flash-RL-Q8_0.gguf` | 2,383,728,864 |
| `mmproj-MiMo-V2.6-Flash-RL-BF16.gguf` (only for images) | 2,748,509,792 |

Use identical absolute paths on both hosts; the launcher passes them to rank 1
verbatim. Shard 1 is metadata plus the split index; the tensors live in shard 2,
which must sit beside it.

## 3. Dense sidecar

The Q8_0 dense attention projections are requantized to Q4_0 in a sidecar GGUF
that the loader grafts over the originals (`GUFO_MIMO_DENSE_SC`). This is the
optimization behind the published decode numbers. Generate it from **shard 2**:

```sh
pip install gguf numpy
python3 tools/mimo2_requant_dense.py \
  --src ~/models/mimo26-flash-rl/MiMo-V2.6-Flash-RL-MXFP4-00002-of-00002.gguf \
  --out ~/models/mimo26-flash-rl/dense-full-q4_0.gguf \
  --type q4_0 --head q4_0 \
  --mtp ~/models/mimo26-flash-rl/mtp-MiMo-V2.6-Flash-RL-Q8_0.gguf
```

Expected output: 3,541,900,640 B, md5 `87060794b099d820a08eb3b6e049a307`.
Copy it to the same path on both hosts. Without the sidecar the engine runs, but
reads the Q8_0 originals and is slower.

## 4. Configure and launch

```sh
git clone https://github.com/kaka86mm/gufo-tp2-mimo26
cd gufo-tp2-mimo26
# edit run/env.sh: RANK1, RANK0_IP, TOKEN, MODEL, MTP, DENSE_SIDECAR, cache dirs
SESSIONS=6 CONTEXT=204800 ./run/start-tp2-mimo.sh
```

Watch `$HOME/logs/mimo-rank0.log` for `rdma_ready` and `event=listening`, then:

```sh
curl -s localhost:8080/health
```

## 5. Verify

```sh
./run/bench/perf-accept.sh
```

On this hardware the published 0.15.0 line gives:

- single stream 29.2–30.1 t/s at 1K, 31.5–32.6 at 8K, 29.3 at 28K, 23.6 at
  55K, 19.4–21.0 at 110K;
- six counting streams 85.5–86 t/s at 1K, 52–53.6 at 55K, 36 at 110K;
- cold prefill 682 t/s at 8K down to 238 t/s at 150K;
- a 193K prefix restored from the L2 disk in 7.8 s after a restart;
- needles pass at every depth tested.

The acceptance battery and the full prefill ladder are in
`./run/bench/prod-full-test.sh`. Results are sensitive to queue state: measure
the mixed six-way after a drain, not right after a cold prefill.

## Pinned values

| item | value |
|---|---|
| engine tag | `mimo2-0.15.0` |
| measured binary | `96e5afcc8d56953f9984e6a4f4e6f79e` |
| model repo | `ggml-org/MiMo-V2.6-Flash-RL-GGUF` (MIT) |
| trunk shard 2 | 167,363,516,512 B |
| MTP Q8_0 | 2,383,728,864 B |
| dense sidecar | 3,541,900,640 B, md5 `87060794b099d820a08eb3b6e049a307` |
| production flags | `SESSIONS=6 CONTEXT=204800`, 28 GiB L2, 3 GiB staging, 1 GiB L1 |
