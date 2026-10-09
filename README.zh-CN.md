# gufo-tp2-mimo26

**MiMo-V2.6-Flash-RL（309B 总参 / 15B 激活 的 MoE）跑在两台 128 GB 的 AMD Strix Halo 上、合成一个 250 GB 的推理池：6 路 × 200K 上下文，冷预填速率随深度从 711 降到 288 tok/s，重启后靠磁盘续传缓存把一次 193K token 的冷预填（692 s）变成 7.8 s。**

[English](README.md) · 基于 [gufo](https://github.com/neuhaus/gufo) · 传输层来自 [gufo-tp2-tb4-rdma](https://github.com/kaka86mm/gufo-tp2-tb4-rdma)

两台 Strix Halo（Ryzen AI MAX+ 395，各自 128 GB 统一内存，gfx1151，ROCm）合扛一个 MoE 模型：48 层、256 专家（激活 8）、MXFP4 权重，外加一个 MTP 草稿头（Q8_0，d=7）。每一层都按 TP2 切分、经 USB4 / 雷电 4 RDMA 互联。服务层常驻六个 200K token 的会话，并把前缀快照落到一块**重启可用**的磁盘续传缓存上。

## 实测结果

硬件：2× Strix Halo（Ryzen AI MAX+ 395，gfx1151，128 GB 统一内存；**两块板子不同**——其中一块可用内存少约 2.25 GiB，这就是下面上下文的定容依据），Ubuntu 24.04，kernel 7.0.0-34，ROCm 7.2.4，传输层用姊妹仓库的 TB4 RDMA 写条带。模型：MiMo-V2.6-Flash-RL MXFP4 + MTP 草稿。

**冷预填**（全新前缀、单流）：

| prompt token | 墙钟 | 每 token | 速率 |
|---|---:|---:|---:|
| 8,314 | 11.7 s | 1.41 ms | 711 tok/s |
| 18,513 | 25.4 s | 1.37 ms | 729 tok/s |
| 36,712 | 58.0 s | 1.58 ms | 633 tok/s |
| 79,911 | 186.2 s | 2.33 ms | 429 tok/s |
| 141,513 | 408.1 s | 2.88 ms | 347 tok/s |
| 192,910 | 692.0 s | 3.59 ms | 288 tok/s |

**前缀续传**（同一 prompt 再来一次；第一行走内存，后三行是**重启之后只剩磁盘缓存**的情况）：

| prompt token | 路径 | 墙钟 | 恢复耗时 | 加速 |
|---|---:|---:|---:|---:|
| 79,911 | L1 内存 | **1.2 s** | 0.17 s | 155× |
| 68,911 | L2 磁盘 | **2.2 s** | 1.29 s | 60× |
| 141,513 | L2 磁盘 | **25.5 s** | 4.76 s | 24× |
| 192,910 | L2 磁盘 | **7.8 s** | 3.76 s | **89×** |

一个 195K 的请求叠加在已有 143K 前缀之上时，只冷算了 49,550 token 的增量（271.7 s，而不是 692 s）。所有埋在 60% 深度处的 needle 在这些路径上全部答对。

**解码**——单流 **34.7 t/s**；6 路并发计数 **92.6 / 92.5 / 92.1 t/s** 聚合；6 路混合 cohort **55.0 t/s**。10 分钟连续 6 路浸泡：**29/29 轮全清**，73.0–92.8 t/s，GTT 全程平（106,397 → 106,479 MB）。

**并发预填**——六路各自预填约 28.9K token：六路全部完成，173,604 token / 363.7 s = **聚合 477 tok/s**（同深度单流水位的 75%）。

**内存包络**（整场测试两机 10 秒采样）——GTT 峰值 **106,999 MB，两机完全一致**，可用内存最低 **7.8 GB（rank0）/ 6.3 GB（rank1）**。实测的分配失败点在 GTT ≈ 109.7 GB，也就是说出货配置离墙还有约 3 GB。完整表格、**失败配置**和方法学见 [docs/BENCHMARKS.md](docs/BENCHMARKS.md)。

## 哪些是我们的，哪些是上游 gufo

这是一次**被当真使用的 gufo fork**，界线值得说清。上游 gufo 提供引擎内核（源自 llama.cpp 的推理循环、采样器、服务 CLI）、TP2 传输与 KV/续传缓存子系统——那是承重的那一半，不是我们拍的。

本仓库新增、也就是上面数字所测量的部分：

- **引擎里的 MiMo-V2.6-Flash 模型支持**——这个 309B/15B MoE 的移植（专家路由、MXFP4 专家路径、滑动/全注意力分层、MTP 接线）是为 gufo 实现的。
- **内核与格式优化**——4-bit 稠密 sidecar 嫁接（加载时稠密权重 6,583 MB → 3,485 MB）、fp16 all-reduce（`GUFO_AR_F16`）、共享 KV 的解码注意力（同一 KV head 的 16 个 q head 经 LDS 复用暂存行：65K 深度单流 +48%）、深度闩锁（请求内不再重复决定 all-reduce 宽度：70K +43%）、宽预填注意力内核与融合 MXFP4 MoE 解码层。全部条目——**包括失败的**——记录在 [docs/OPTIMIZATIONS.md](docs/OPTIMIZATIONS.md)。
- **本仓库的服务与生命周期层**——启动器、systemd 主管（GTT 失控护栏、对端消失即杀、从回滚点自动恢复）、成对就绪的恢复路径、L1/L2 续传缓存转正，以及产出上面每一个数字的验收套件。
- **模型重打包线**（EXL3 / 低位宽重打包）与 **TB4 RDMA 传输层**（在[姊妹仓库](https://github.com/kaka86mm/gufo-tp2-tb4-rdma)）。

这里没有任何东西取代 gufo，上游的 MIT 声明在 [LICENSE](LICENSE) 中保留。

## 目录结构

```
run/    start-tp2-mimo.sh      TP2 协同启动器（rank0 本地，rank1 走 ssh）；所有开关可覆盖，见 run/env.sh
        env.sh                启动器会 source 的参数块，逐项带注释
        bench/                测量套件：验收电池 + 预填阶梯 + 并发预填 + 浸泡、L2 证明，及其用到的小型 harness
deploy/ mimo-supervisor.sh     生命周期的拥有者：GTT 护栏、对端消失即杀、对端还在时自动恢复
        mimo-supervisor.service
        restore-prod.sh       停两 rank、放回钉住的二进制、启动、等待**成对**就绪（health 200 且对端进程存活）；持排他锁
        mimo-stop.sh          停两 rank，必要时升级到 SIGKILL
        warmup.sh             恢复后主管会跑的一发预热请求
docs/   CONFIGURATION.md       每个 flag 与环境变量、生产值、默认值与背后的坑——先看这份
        OPTIMIZATIONS.md       引擎侧优化全集，赢的与输的都带测量
        BENCHMARKS.md          完整数据，含失败配置与方法学
        PITFALLS.md            咬过我们的每一条，免得它再咬你
```

## 快速开始

1. **先通传输层**：按 [gufo-tp2-tb4-rdma](https://github.com/kaka86mm/gufo-tp2-tb4-rdma) 把 RDMA 对拉起来，确认引擎日志里出现 `rdma_ready`。本仓库脚本假设两台都有 `usb4_rdma0`。
2. **模型文件在两台上同路径**：MXFP4 主干、MTP 草稿、以及稠密 sidecar（`dense-full-q4_0.gguf`，稠密 sidecar 优化的嫁接目标）。改 `run/env.sh` 里的 `MODEL` / `MTP` / `DENSE_SIDECAR`。
3. **引擎二进制**放到两台的 `$HOME/gufo-mimo2-bin`，并留一份钉住的副本（`gufo-mimo2-bin.splitk`）给回滚路径用。
4. 编辑 `run/env.sh`：主机、TP 控制令牌（**共享密钥，两台必须一致**）、模型路径、两个缓存目录。然后启动：`SESSIONS=6 CONTEXT=204800 ./run/start-tp2-mimo.sh`，等会合与加载完成。
5. **把生命周期交给 systemd**：拷 `deploy/mimo-supervisor.service`、改正路径、`systemctl enable --now mimo-supervisor`。此后主管会在无人值守时自己恢复（并且只要 `/tmp/mimo-no-supervise` 存在就不插手——测试窗口会持有它）。
6. **用测量套件自检**：`./run/bench/perf-accept.sh`（电池、解码、6 路、混合、needle、L2 重启证明），再 `./run/bench/prod-full-test.sh`（追加冷预填阶梯、并发预填与 10 分钟浸泡）。

## 配置

每个 flag 的生产值、默认值与背后的坑都在 [docs/CONFIGURATION.md](docs/CONFIGURATION.md)。最要紧的五项：

| 开关 | 这里的值 | 为什么 |
|---|---|---|
| `--sessions` / `--context` | `6` / `204800` | 是从较小那台主机的内存**反解**出来的，不是拍脑袋——见下 |
| `--cache-disk` | rank0 `$HOME/cache-disk`，rank1 `/mnt/data1t/cache-disk` | 磁盘续传缓存；**必须是真实目录**——符号链接会在加载期被拒，而且其中一台的系统盘放不下 28 GiB 快照 |
| `--cache-disk-bytes` | `30064771072`（28 GiB） | 六个约 4 GB 的快照 + 暂存余量 |
| `--cache-disk-staging-bytes` | `3221225472`（3 GiB） | 这是**上限不是预留**；设小了会比它大的快照被静默拒绝（200K 前缀的快照约 2.6 GB） |
| `--cache-ram-bytes` | `1073741824`（1 GiB） | L1 内存快照池；默认「空闲内存的一半、上限 32 GiB」可能在被算出的那一刻就过大 |

上下文是一条内存方程，不是偏好：`GTT ≈ 89.7 GB 固定（权重+工作区+MTP）+ Σ 每会话(344 MB + 上下文 × 12.3 KB)`（每 rank）。五路 256K 加载占用 107,507 MB、能跑；六路 256K 需要约 111 GB，在较小那块板上撞到约 109.7 GB 的墙。六路 200K **实测 106,397 MB**——比 5×256K 的工作点还低约 1 GB、离墙 3 GB，整场测试最紧的时刻仍余 6.3 GB 空闲内存。这就是本仓库出货 6×200K 的全部理由。

## 坑

完整清单在 [docs/PITFALLS.md](docs/PITFALLS.md)；三条真的花掉时间的：

- **缓存目录是符号链接会让加载直接失败**（`TP disk cache directory: Not a directory`），并连带把整个 pair 拉下水——另一侧 rank 会以 `tp_pair_lost` 退出。
- **`--cache-disk-staging-bytes` 小于快照大小会静默杀掉磁盘缓存**：目录只是不再增长，请求报告 `cache_miss_reason=no_checkpoint`——读起来像"这个前缀没有检查点"，而不是"你的快照被拒了"。
- **就绪不等于 `event=listening`**：这一行在 200K 上下文的 KV 分配完成前就会出现，而且 rank0 在**对端已经没了**的时候照样答 `/health`（约一分钟后才自己退出）。本仓库的恢复路径等的是 health 200 **且**对端进程存活——因为一次「报告成功但 rank1 已死」的恢复，比一次「报告失败」糟糕得多。

## 复现这些数字

除标注重启的步骤外，全部测量都是对 `http://127.0.0.1:8080` 的客户端 HTTP。`run/bench/perf-accept.sh` 是验收电池（质量用例、单流/6 路/混合解码、冷 needle、一次 L1 重放、一次用来证明磁盘缓存的重启）；`run/bench/prod-full-test.sh` 追加冷预填阶梯、六路并发预填（两机内存采样）与浸泡。两者把产物写到 `/tmp` 并打印汇总；引擎自己的视角（`prefill_tps`、`cache=`、`cached_tokens`、`cache_restore_ms`）在 `$HOME/logs/mimo-rank0.log`。

## 致谢

引擎：[gufo](https://github.com/neuhaus/gufo)（MIT）——本仓库是它之上的部署、调优与测量层。传输层：[gufo-tp2-tb4-rdma](https://github.com/kaka86mm/gufo-tp2-tb4-rdma)。硬件：2× AMD Ryzen AI MAX+ 395（Strix Halo，gfx1151）。