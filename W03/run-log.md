# 跑通记录：我亲手敲了哪些命令，每一步在干什么

> 规则：先查清"有没有"，再决定"装不装"；每条命令都写清目的和预期输出。

## 0. 环境先摸清楚

```bash
which gcc ; gcc --version
# 目的：确认编译器在不在、什么版本。已有 GCC 16.2.0（w64devkit），不需要装。
# 预期输出：gcc.exe (GCC) 16.2.0

which make ; make --version
# 目的：后面写 Makefile/脚本要用。已有。

lscpu | head -20        # 服务器上跑：看核数/频率/缓存
nproc                   # 本机 20 逻辑核；服务器 hzcu-hpct 为 128
```

**"装东西之前先问三件事"的结论**：

| 问题 | 答案 |
|---|---|
| 已经有了吗？ | 编译器有（gcc 16.2.0）；`perf` **本机没有**（Windows 不带 Linux perf） |
| 有没有同类工具？ | Windows 侧同类：ETW 采样（`xperf`）、`gprof`；Linux 侧：`valgrind --tool=callgrind`、`gprof` |
| 有没有更新的版本？ | gcc 已是最新稳定线；`perf` 与内核版本绑定，**只能装发行版配套的 `linux-tools-$(uname -r)`**，不能随便装 |

> 结论：不在 Windows 上硬装 perf；`perf` 一律去 `hzcu-hpct`（Ubuntu 22.04 + Slurm）上跑，见 [perf.md](perf.md)。

## 1. 取源码

```bash
git clone https://github.com/HZCU-HPC-Team/2022_IPCC.git
# 组织仓库拿到 2022_IPCC/pivot.tar

mkdir pivot && tar -xf pivot.tar -C pivot && cd pivot
ls -l
# 目的：解开源码包，确认三件套齐全。
# 输出：pivot.c / uniformvector-2dim-5h.txt / refer-2dim-5h.txt
```

**输入文件的第一行就是全部参数**（这点必须自己看一眼，不要猜）：

```bash
head -1 uniformvector-2dim-5h.txt
# 2 500 2   → dim=2, n=500, k=2
wc -l uniformvector-2dim-5h.txt refer-2dim-5h.txt
# 501 行（1 行头部 + 500 个点）；refer 2000 行（1000 max + 1000 min）
```

## 2. 编译

```bash
gcc pivot.c -lm -o pivot
# 目的：赛题手册给的参考命令（等价 -O0）。
# 关键：-lm 必须加，否则链接 pow/sqrt 会报 undefined reference to `pow'
echo $?        # 0 = 链接成功
```

```bash
gcc -O2 -o pivot_O2 pivot.c -lm
# 目的：第一档优化，先确认"同一份代码能快多少"
```

## 3. 运行（单次要几分钟，别在前台等）

```bash
time ./pivot_O2 uniformvector-2dim-5h.txt > run.log
# 目的：跑出 result.txt，同时看 wall time。
# 本机实测（-O2）：wall 41.1 s，程序自报 Using time : 40936 ms
```

服务器上要挂后台，避免 SSH 断线把进程带走：

```bash
nohup ./pivot_O2 uniformvector-2dim-5h.txt > run.log 2>&1 &   # 或者 tmux new -s pivot
tmux new -s pivot        # 推荐：tmux 里跑，断开重连还在
tail -f run.log
```

`run.log` 前几行会打印 `dim = 2, n = 500, k = 2`，中间是每个 pivot 组合的迭代日志（**代码注释里写了这段打印可以删**），最后两行是：

```
max : 143 351 117761.647418
min : 83 226 43769.849602
```

## 4. 先对再快：结果必须和 refer 一致

```bash
diff result.txt refer-2dim-5h.txt && echo SAME
# 目的：字节级比对 2000 行输出。输出 SAME 才算"跑通"。
```

本机实测：`-O0 / -O1 / -O2 / -O3 / -O2 -march=native / -O3 -march=native` 六种编译方式，`result.txt` 全部与 refer **逐字节相同**（见 [compile-opts.md](compile-opts.md)）。

## 5. 计时口径（赛题规定）

手册第 3 条：成绩以程序打印的 `Using time` 为准，**不含读写文件时间**，且不得移动计时函数位置。所以：

- 程序内的 `gettimeofday` 包住的是 `Combination(...)` 那一段，这才是官方可比口径；
- 外面 `time` 的 wall 会多出读文件、写 `result.txt`、终端输出迭代日志的时间，只能当参考。

本机对照：`-O2` 外面 wall 41.09 s vs 程序内 40.94 s，差 0.15 s ≈ 读写文件 + 启动开销。

## 6. 踩过的坑

| 现象 | 原因 | 解法 |
|---|---|---|
| `undefined reference to 'pow'` | 只写了 `gcc pivot.c -o pivot` | 补 `-lm` |
| `uniformvector-2dim-5h.txt file not found.` | 在别的目录运行，程序用相对路径 | `cd` 到数据所在目录，或把文件名作为参数传进去 |
| 前台跑被 SSH 断线杀掉 | 进程挂在登录 shell 下 | `nohup ... &` 或 `tmux` |
| 终端被几千行迭代日志刷屏 | `Combination()` 里 k-2 层每轮都 `printf` | 重定向到 `run.log`；优化版会删掉这段打印 |

## 7. 服务器（hzcu-hpct）上的实操与两个真坑

### 7.1 环境确认

```bash
ssh -p 9446 cyp@10.61.190.8            # 端口 9446，不是 22
uname -r                                # 5.15.0-191-generic
gcc --version | head -1                 # gcc 12.3.0
nproc                                   # 128
lscpu | grep -E 'Model name|MHz|L3'     # Xeon Gold 6430 / 3400MHz / L3 120MiB

# perf 先查"有没有"，再查"能不能用"
perf --version                          # perf 5.15.209（已装，不用装）
cat /proc/sys/kernel/perf_event_paranoid  # -1 → 普通用户即可采集，不用 sudo
```

### 7.2 坑 1：`nohup` 也会被登录会话回收

第一次用 `nohup bash server-run-all.sh &` 挂后台，中途断开 SSH 后进程就没了（跑到一半的 O0 计时丢失）。原因：登录会话被 systemd-logind 收尾时，整个 user slice 会被清。

**可靠做法**（按可靠性排序）：

1. `tmux new -s pivot` → 里面跑 → `Ctrl-b d` 脱离；断了 `tmux attach -t pivot` 回来；
2. `setsid nohup ./cmd > log 2>&1 < /dev/null &`（脱离控制终端与会话）；
3. 干脆别断：保持一个常连的 SSH 会话（我最后就是用长连接把脚本跑完的）。

### 7.3 坑 2：`pkill -f server-run-all.sh` 会把自己也杀了

`pkill -f` 匹配的是完整命令行，而**自己那条 `bash -c "pkill -f server-run-all.sh ..."` 的命令行里就含这个字符串**，于是自杀，命令什么都不输出，很容易误判成"已经杀干净了"。

```bash
pkill -f server-run-all.sh     # ✗ 可能杀掉自己
pkill -x pivot_O0              # ✓ 按进程名精确匹配
ps -o pid,etime,time,%cpu -C pivot_O0   # ✓ 先看清楚再动手
```

### 7.4 计时结果（服务器 vs 本机）

| 档位 | 服务器（gcc 12.3 / Xeon 6430） | 本机（gcc 16.2 / i7-13650HX） |
|---|---|---|
| `-O0` | 500.47 s | 302.58 s |
| `-O1` | 97.30 s | 33.04 s |
| `-O2` | **60.65 s**（最快） | 37.24 s |
| `-O3` | 61.95 s | **33.28 s**（最快） |

服务器单核更慢的原因：共享机 + 全核负载，`perf stat` 实测有效频率只有 **2.596 GHz**；本机单核能跑到 4.x GHz。**"服务器核多"和"单线程快"完全是两件事**——这也正是本题（单线程 baseline，128 核闲置）最值得并行化的地方。
