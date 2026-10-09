# gufo-tp2-mimo26

把 MiMo-V2.6-Flash-RL 拆到两台 AMD Strix Halo 上跑。

模型是 309B 的 MoE，每个 token 激活 15B（专家是 MXFP4）。单台 128 GB 差得远，两台刚刚够——"刚刚够"就是这个仓库的全部主题。现在它同时跑六个 200K token 的会话；冷预填从短提示的 711 tok/s 一路掉到 195K 时的 288 tok/s；服务重启之后，见过的前缀直接从磁盘快照里回来：冷跑要 692 秒的 193K 提示词，7.8 秒就能接着用。

引擎是 [gufo](https://github.com/neuhaus/gufo)（MIT），我在 fork 里加了 MiMo 的移植和不少内核改动。两台机器之间的链路是另一个仓库 [gufo-tp2-tb4-rdma](https://github.com/kaka86mm/gufo-tp2-tb4-rdma)。这两个是前提，本仓库是其余的东西：启动器、看着服务别死的 supervisor、跑数的脚本，和这些笔记。

## 实测数字

两台 AMD Ryzen AI MAX+ 395（gfx1151，各 128 GB 统一内存），Ubuntu 24.04，kernel 7.0.0-34，ROCm 7.2.4，传输层走 TB4 RDMA。两块板子不一样：其中一块可用内存少 2.25 GiB，下面的上下文就是按它定的。模型是 MiMo-V2.6-Flash-RL MXFP4 加 Q8_0 的 MTP 草稿头（d=7）。

全部数据就这一张表：

| 测试 | 规模 | 墙钟 | 速率 | 备注 |
|---|---|---:|---:|---|
| 冷预填 | 8,314 token | 11.7 s | 711 tok/s | |
| 冷预填 | 18,513 token | 25.4 s | 729 tok/s | 曲线的峰值 |
| 冷预填 | 36,712 token | 58.0 s | 633 tok/s | |
| 冷预填 | 79,911 token | 186.2 s | 429 tok/s | |
| 冷预填 | 141,513 token | 408.1 s | 347 tok/s | |
| 冷预填 | 192,910 token | 692.0 s | 288 tok/s | 只有峰值的 40% |
| 续写已有前缀 | 143K 前缀上新增 49,550 token | 271.7 s | | 只算增量 |
| 同一提示词，内存快照（L1） | 79,911 token | 1.2 s | | 155x；恢复本身 0.17 s |
| 同一提示词，重启后（L2 磁盘） | 68,911 token | 2.2 s | | 60x；恢复 1.29 s |
| 同一提示词，重启后（L2 磁盘） | 141,513 token | 25.5 s | | 24x；恢复 4.76 s |
| 同一提示词，重启后（L2 磁盘） | 192,910 token | 7.8 s | | 89x；恢复 3.76 s |
| 解码，单流 | | | 34.7 tok/s | |
| 解码，六路计数 | | | 92.6 tok/s | 三轮 92.6 / 92.5 / 92.1 |
| 解码，六路混合 | | | 55.0 tok/s | 排空后测的，见下 |
| 并发预填，六路同时 | 173,604 token（6 x 28.9K） | 363.7 s | 477 tok/s | 同深度单流的 75% |
| 十分钟浸泡 | 六路连续跑 | | 73.0-92.8 tok/s | 29/29 轮全清，GTT +82 MB |
| 内存 | 6x200K | | GTT 峰值 106,999 MB | 最紧时剩 6.3 GB；墙在 ~109.7 GB |

"冷"指这个进程从没见过这段提示词，没有任何缓存可命中。恢复时间都是引擎自己报的 `cache_restore_ms`，速率都是打 `http://127.0.0.1:8080` 的客户端墙钟。预填曲线在 18K 见顶、之后一路衰减：48 层里 12 层是全注意力，要为整段上下文付账，另外 36 层只看 128 个 token 的历史。这些提示词里埋的 needle 在以上所有路径里都答对了。并发行有个前提：必须排空后再测——紧接着上一批测混合六路只有 21 t/s，紧跟一次 59K 冷预填只有 15.8 t/s，那量的是排队时间不是解码。

每条数字的引擎侧证据、快照大小、失败的配置：见 [docs/BENCHMARKS.md](docs/BENCHMARKS.md)。

## 哪些是我写的，哪些是 gufo 的

引擎核心、TP2 传输、整套续传缓存机制都是 gufo 的，难的部分基本都在那儿，不是我做的。

我在上面加的东西：

- MiMo-V2.6-Flash 的移植：专家路由、MXFP4 专家路径、12 全层 / 36 滑窗的注意力布局、MTP 的接线。
- 内核和格式的活：q4_0 稠密 sidecar（加载时稠密权重 6,583 MB → 3,485 MB）、fp16 all-reduce、共享 KV 的解码注意力（65K 深度 +48%）、深度闩锁（70K +43%，请求内不再反复重算 all-reduce 宽度）、宽预填注意力内核、融合的 MXFP4 解码 MoE。
- 本仓库的服务和生命周期层：启动器、systemd supervisor（GTT 护栏、对端没了就杀本机、自动恢复）、等"成对就绪"的恢复路径、L1/L2 缓存的转正。
- 测量脚本。上面每个数字都是这些脚本跑出来的。

内核那部分**输掉的实验也在**，连测量一起放在 [docs/OPTIMIZATIONS.md](docs/OPTIMIZATIONS.md)——主要是写给自己看，免得过两天又去试一遍。

## 目录

```
run/    start-tp2-mimo.sh      TP2 启动器（rank0 本地，rank1 走 ssh）；所有开关可覆盖，见 run/env.sh
        env.sh                 带注释的参数块
        bench/                 测量套件：验收电池、预填阶梯、并发预填、浸泡、L2 证明，及其用到的小 harness
deploy/ mimo-supervisor.sh     生命周期总管：GTT 护栏、对端消失即杀、自动恢复
        mimo-supervisor.service
        restore-prod.sh        停两 rank、放回钉住的二进制、启动、等 health 200 且对端进程在；持排他锁
        mimo-stop.sh           停两 rank，杀不掉就升级 SIGKILL
        warmup.sh              恢复后跑一发预热请求
docs/   CONFIGURATION.md       每个 flag / 环境变量：这里的值、默认值，以及为什么
        OPTIMIZATIONS.md       引擎侧的活：成了的和输了的
        BENCHMARKS.md          全部数据、失败配置、方法学
        PITFALLS.md            咬过我的每一条
```

## 跑起来

1. 先把 RDMA 链路拉起来（按 [gufo-tp2-tb4-rdma](https://github.com/kaka86mm/gufo-tp2-tb4-rdma)），确认引擎日志里出现 `rdma_ready`。这里的脚本都假设两台有 `usb4_rdma0`。
2. 模型文件在两台放同样路径：MXFP4 主干、MTP 草稿、稠密 sidecar（`dense-full-q4_0.gguf`）。改 `run/env.sh` 里的 `MODEL` / `MTP` / `DENSE_SIDECAR`。
3. 引擎二进制放到两台的 `$HOME/gufo-mimo2-bin`，旁边留一份钉住的副本（`gufo-mimo2-bin.splitk`）给回滚用。
4. 编辑 `run/env.sh`：主机、TP 控制令牌（共享密钥，两台必须一致）、模型路径、两个缓存目录。然后 `SESSIONS=6 CONTEXT=204800 ./run/start-tp2-mimo.sh`。
5. 交给 systemd：`deploy/mimo-supervisor.service` 改正路径，`systemctl enable --now mimo-supervisor`。之后服务掉线它自己拉。测试窗口里放一个 `/tmp/mimo-no-supervise`，它就完全不插手。
6. 用脚本自检：先 `./run/bench/perf-accept.sh`（电池、解码、六路、混合、needle、L2 重启证明），再 `./run/bench/prod-full-test.sh`（加预填阶梯、并发预填和十分钟浸泡）。

## 真正要紧的开关

全部 flag 和坑在 [docs/CONFIGURATION.md](docs/CONFIGURATION.md)。最先会搞错的五个：

| 开关 | 这里的值 | 为什么 |
|---|---|---|
| `--sessions` / `--context` | `6` / `204800` | 从较小的那块板子的内存反解出来的，看下面 |
| `--cache-disk` | rank0 `$HOME/cache-disk`，rank1 `/mnt/data1t/cache-disk` | L2 磁盘缓存。**必须是真实目录**：符号链接会让加载直接失败，而 rank1 的系统盘放不下 28 GiB 快照 |
| `--cache-disk-bytes` | `30064771072`（28 GiB） | 六个约 4 GB 的快照加暂存余量 |
| `--cache-disk-staging-bytes` | `3221225472`（3 GiB） | 是**上限不是预留**。设小了，比它大的快照会被静默拒收（200K 前缀的快照约 2.6 GB） |
| `--cache-ram-bytes` | `1073741824`（1 GiB） | L1 内存快照池。默认值（"空闲内存的一半、最多 32 GiB"）会被算在错误的时刻，占太多 |

上下文是个内存方程，不是偏好。这两台机器上实测，每 rank：

```
GTT ~ 89.7 GB 固定（权重 + 工作区 + MTP）
    + 各会话之和（344 MB + 上下文 x 12.3 KB）
```

5x256K 跑在 107,507 MB。6x256K 要 111 GB 左右，加载到 109.7 GB 就崩。6x200K 实测 106,397 MB，离墙约 3 GB，整场测试最紧时还剩 6.3 GB 空闲内存。200K 就是这么来的。

## 会咬人的地方

完整清单在 [docs/PITFALLS.md](docs/PITFALLS.md)。最花时间的三条：

- 缓存目录是符号链接会让整个加载失败（`TP disk cache directory: Not a directory`），另一台跟着以 `tp_pair_lost` 退出。
- `--cache-disk-staging-bytes` 小于快照大小会静默杀掉磁盘缓存：目录只是不再增长，请求报告 `cache_miss_reason=no_checkpoint`，读起来像"这个前缀没有检查点"，而不是"你的快照被拒了"。我用 256 MiB 跑了一段时间，还以为缓存是好的。
- 就绪不等于 `event=listening`。那行日志在 200K 的 KV 分配完成之前就会打出来，而且 rank0 在对端已经没了之后还会继续答 `/health` 大约一分钟。这里的恢复路径等的是 health 200 **且**对端进程活着——一次"报告成功但 rank1 已经死了"的恢复，比"报告失败"糟糕得多。

## 复现

除了标注重启的步骤，全部是打 `http://127.0.0.1:8080` 的客户端 HTTP。`run/bench/perf-accept.sh` 和 `run/bench/prod-full-test.sh` 把产物写到 `/tmp` 并打印汇总。引擎自己的视角在 `$HOME/logs/mimo-rank0.log`（`prefill_tps`、`cache=`、`cached_tokens`、`cache_restore_ms`），单请求细节在响应的 `usage.gufo` 里。

## 致谢

引擎：[gufo](https://github.com/neuhaus/gufo)（MIT）。传输层：[gufo-tp2-tb4-rdma](https://github.com/kaka86mm/gufo-tp2-tb4-rdma)。硬件：2x AMD Ryzen AI MAX+ 395。