# perf：给程序做"体检"（本周重点）

> 结构：**它是什么** → **三件套各干什么** → **我怎么采集（环境/命令/参数/次数）** → **实测数据与解读** → **为什么慢、怎么改** → **本机无 perf 时的替代测量**。
> 采集机：`hzcu-hpct`（Xeon Gold 6430 ×2 socket / 128 线程 / 503 GB / Ubuntu 22.04 / kernel 5.15.0-191 / gcc 12.3.0 / perf 5.15.209）。
> 原始数据：[data/server-perf/stat.txt](data/server-perf/stat.txt)、[report.txt](data/server-perf/report.txt)、[annotate.txt](data/server-perf/annotate.txt)。

---

## 1. perf 是什么

`perf` 是 Linux 内核自带的性能分析工具，背后是内核 **perf_events** 子系统，同时吃两种数据源：

| 数据源 | 原理 | 能回答的问题 |
|---|---|---|
| **硬件计数器（PMU）** | CPU 里的 Performance Monitoring Unit 有几个可编程计数器，精确数 cycles、instructions、cache miss、branch miss | "算得多还是等内存多？" |
| **采样（sampling）** | 某事件（如 cycles）溢出时触发中断，内核记下当时的 **IP + 调用栈** | "时间花在哪个函数/哪一行？" |

前者是**精确计数**（跑一次一个总数），后者是**统计推断**（按比例外推）。`stat` 用前者，`record/report` 用后者。

> 版本提醒：`perf` 与内核绑定，包名是 `linux-tools-$(uname -r)`。这台机器的 `perf_event_paranoid = -1`（全开），普通用户可直接采集，不需要 sudo。

---

## 2. 三件套各干什么

| 命令 | 一句话 | 产物 | 什么时候用 |
|---|---|---|---|
| `perf stat` | **计数**：整段程序跑了多少 cycles/instructions/miss | 文本统计表 | 判断计算密集还是访存密集、算 IPC |
| `perf record` | **采样**：按频率抓 IP 与调用栈 | `perf.data` | 想知道哪段代码最热 |
| `perf report` | **读** `perf.data` | 热点表 / 调用链 | 看函数占比 |
| `perf annotate` | 下钻到**指令级** | 带百分比的汇编 | 看循环里到底哪条指令在等 |

---

## 3. 采集方案（环境 / 命令 / 参数 / 次数）

**编译**（`-g` 必须有，否则 report 只有地址没有函数名）：

```bash
gcc -O2 -g -fno-omit-frame-pointer -o pivot_O2 pivot.c -lm
```

**计数**（3 次，绑核）：

```bash
perf stat -r 3 \
  -e task-clock,cycles,instructions,cache-references,cache-misses,branch-instructions,branch-misses,\
context-switches,page-faults,minor-faults,major-faults,L1-dcache-loads,L1-dcache-load-misses,LLC-loads,LLC-load-misses \
  taskset -c 8 ./pivot_O2 uniformvector-2dim-5h.txt > stat.stdout.log 2> stat.txt
```

**采样**（999 Hz，记调用栈，1 次）：

```bash
perf record -F 999 -g -o perf.data -- taskset -c 8 ./pivot_O2 uniformvector-2dim-5h.txt
perf report  -i perf.data --stdio --sort symbol --percent-limit 0.5 > report.txt
perf annotate -i perf.data --stdio -s SumDistance > annotate.txt
```

| 采集要素 | 值 |
|---|---|
| 环境 | hzcu-hpct / Ubuntu 22.04 / kernel 5.15.0-191 / gcc 12.3.0 / perf 5.15.209 / `perf_event_paranoid=-1` |
| 硬件 | Intel Xeon Gold 6430（32C/64T ×2 socket = 128 线程，2.6 GHz 实测有效频率 2.596 GHz），L3 120 MiB |
| 绑定 | `taskset -c 8`（单核，程序本身单线程） |
| 次数 | `stat`：`-r 3`（3 次取均值/看波动）；`record`：1 次，999 Hz × ~60 s ≈ **60016 个样本** |
| 同时刻其他负载 | 机器是共享的（93 GB 内存被他人占用），故计时口径有环境噪声；perf 的比率类指标不受影响 |

---

## 4. 实测数据（3 次均值 ± 标准差）

### 4.1 `perf stat` 原始

```
Performance counter stats for 'taskset -c 8 ./pivot_O2 uniformvector-2dim-5h.txt' (3 runs):

      59,890.99 msec  task-clock        # 0.999 CPUs utilized      ( ± 0.17% )
 155,495,397,364    cycles            # 2.593 GHz                 ( ± 0.17% )
 975,289,914,930    instructions      # 6.26 insn per cycle       ( ± 0.01% )
         852,671    cache-references  # 14.217 K/sec              ( ±16.47% )
         260,451    cache-misses      # 31.581 % of all cache refs( ± 5.80% )
 157,338,268,035    branch-instructions # 2.623 G/sec            ( ± 0.00% )
      63,313,307    branch-misses     # 0.04 % of all branches   ( ± 0.03% )
             157    context-switches
             154    page-faults  (全部是 minor-faults，major-faults = 0)
 125,847,186,364    L1-dcache-loads
       5,312,177    L1-dcache-load-misses  # 0.00 % of L1 accesses( ± 1.00% )
         256,546    LLC-loads
          84,004    LLC-load-misses        # 32.28 % of LL accesses
  59.980 ± 0.102 s  time elapsed
```

### 4.2 派生指标

| 指标 | 计算 | 值 | 判据线 | 结论 |
|---|---|---|---|---|
| IPC | 975.29G / 155.50G | **6.27** | >1.5 偏计算；<0.8 偏访存 | **计算受限**（流水线被打满） |
| 有效频率 | 155.50G / 59.891 s | 2.596 GHz | — | 未跑满 3.4 GHz 睿频（共享机 + 全核负载） |
| L1 命中率 | 1 − 5.31M/125.85G | **99.9958%** | — | 工作集全在 L1 |
| LLC 访问量 | 256,546 次 / 60 s | ~4.3 K/s | 相对 1258 亿次 L1 读 | **内存层次基本没参与** |
| 分支预测失败率 | 63.31M / 157.34G | **0.040%** | >5% 控制流不友好 | 控制流极友好（几乎全预测对） |
| 缺页 | 154（全 minor） | — | — | 12 万次 `malloc/free` 并未产生缺页风暴 |
| 每次内层迭代的代价 | 155.50G / 6.2375e10 | **2.49 cycles** | — | 每 2.49 周期做 1 次"2×fabs+2×max+1×add" |
| 每次内层迭代的指令 | 975.29G / 6.2375e10 | **15.6 条** | — | IPC 高但每迭代指令多（地址计算/循环开销占大头） |

**判定：这是纯计算密集型（准确地说是"标量浮点 + 依赖链受限"），不是访存密集型。**

依据三条，全部有数据：

1. **L1 命中 99.996%、LLC 访问 4.3 K/s**：数据量太小（`rebuiltCoord` = `n·k·8 = 8 KB`），缓存根本不是瓶颈；`cache-misses 31.6%` 看着高，但基数只有 85 万次引用，绝对值 = 26 万次，摊到 60 s 里可以忽略——**看 miss 率必须同时看基数**，这是最容易读错的地方；
2. **IPC = 6.27**：每周期退休 6.27 条指令，说明 CPU 大部分时间在"执行"而不是"等"；
3. **branch-misses 0.04%**：循环边界和 `dis>chebyshev ? dis : chebyshev`（编译成 `maxsd`，不是分支）都预测良好，控制流不是瓶颈。

所以优化方向**不是**"提高缓存命中率/改善数据布局"，而是**减少运算量 + 打断依赖链 + 用向量化/并行**。

### 4.3 `perf report`：热点函数（60016 个样本）

```
Children      Self  Symbol
99.98%     0.00%   __libc_start_call_main
99.98%     0.00%   main
99.98%     0.35%   Combination
99.61%    99.55%   SumDistance      ← 自身 99.55%
```

- `SumDistance` **自身占 99.55%**（子调用占比 99.61%，因为它被 `Combination` 调用）；
- `Combination` 自身只有 **0.35%**（递归 + 排序 + 迭代 `printf` 的开销，实测可忽略——注意这与"看起来在频繁 printf"的直觉相反，因为 stdout 被重定向到文件后开销更低）；
- `main` ≈ 0（`__libc_start_call_main` 那 99.98% 只是调用链上的祖先）。

**与"本机插桩"的交叉验证**：插桩测得的 `SumDistance` 三段合计 = 99.6%（见第 7 节），perf 采样 = 99.61%。两种方法、两种机器、两个数量级不同的原理，给出同一个数——结论可信。

### 4.4 `perf annotate`：循环里到底哪条指令在花时间

`SumDistance` 内层循环的指令级分布（前 8 名，`annotate.txt` 原文）：

| cycles 占比 | 指令 | 含义 |
|---|---|---|
| **19.27%** | `jne 19a0` | 内层循环回边（分支本身预测良好，占比高是"指令流在此汇聚"） |
| **18.00%** | `mov %r11,%rdx` | j 循环起点重置 `rebuiltCoord` 指针 |
| **17.52%** | `mov %edx,%r8d` | 复位 ki 计数 |
| **16.45%** | `maxsd %xmm1,%xmm0` | 切比雪夫核心：取 max（对应 `dis>chebyshev ? dis : chebyshev`） |
| **10.34%** | `movsd (%rdx),%xmm0` | 读 `rebuiltCoord[j*k+ki]` |
| 8.28% | `jmp 1988` | 循环结构跳转 |
| 6.31% | `addsd %xmm1,%xmm3` | `chebyshevSum += chebyshev`（**唯一累加器 → 串行依赖**） |
| 2.99% | `andpd %xmm2,%xmm0` | `fabs` 的位掩码实现 |

两个关键发现：

1. **没有向量化**：全程 `movsd/maxsd/addsd`（标量 SSE2，一次一个 double），没有 `pd` 打包指令。理论上改成可打包的循环结构能拿 2~4 倍；
2. **两条串行依赖链**：`maxsd`（延迟 3~4 cycle）和 `addsd`（延迟 3~4 cycle）都在依赖上一条的结果。这就是为什么 2.49 cycle/迭代、IPC 6.27 却仍然慢——**不是吞吐不够，是延迟在等**。这也解释了为什么本机 `-O2` 曾比 `-O1` 慢、`-march=native` 反而更慢（展开/调度改变了依赖链长度，见 [compile-opts.md](compile-opts.md) 4.1/4.2）。

> 读 `annotate` 有个坑：`mov`/`jmp` 这种"一条周期都用不满"的指令却占 18%，因为**采样的 IP 会偏向"等待发生的那条指令"**（skid），而等待往往落在循环头部那几条准备指令上。所以正确读法是"看整段循环的结构和依赖"，而不是把 18% 当成"这条 mov 很慢"。

---

## 5. 为什么慢：两层原因

| 层 | 原因 | 证据 |
|---|---|---|
| 算法层 | 枚举 `C(n,k) = 124750` 组，每组重算 `n²·k = 5×10⁵` 次比较 → 累计 6.24×10¹⁰ 次 | `SumDistance calls = 124750`（本机插桩）、`Combination` 递归结构 |
| 实现层 | ① 重建坐标每组都从头算（其实与"这一组其它 pivot 是谁"无关）；② `pow(x,2)` 而不是 `x*x`；③ `(i,j)` 与 `(j,i)` 对称却算了两遍；④ 每次都 `malloc/free`；⑤ 单线程；⑥ 内层未向量化、有 2 条串行依赖链 | perf stat IPC/cycles、annotate 指令清单、插桩三段占比 |

## 6. 可以怎么改（W04 动手，本周只判断）

| 改法 | 依据（对应哪条数据） | 预期收益 | 风险 |
|---|---|---|---|
| 预计算 `n×n` 距离矩阵（2 MB），重建坐标变查表 | 重建坐标段占 8.30%，且 `pow/sqrt` 完全可消 | 消掉 2.5×10⁸ 次浮点 + 1.25×10⁸ 次 `sqrt` | +2 MB 内存，可接受 |
| 只算 `i<j` 再 ×2 | `(i,j)`/`(j,i)` 对称、对角为 0 | 内层**直接减半** | 无 |
| 拆累加器（4~8 个 `chebyshevSum` 局部变量再合并）、内层手动展开 | annotate：`addsd`/`maxsd` 串行依赖 | 打断依赖链，理论 IPC 上限翻倍 | 浮点求和顺序变化 → **必须重新 diff refer** |
| 用 AVX2/AVX-512 打包（重排 `rebuiltCoord` 为结构体数组） | annotate：全是标量 `sd` 指令 | 2~4 倍 | 需 `-march=native` 且要解决"打包后 max 归约" |
| OpenMP 遍历组合（128 线程可用） | `C(n,k)` 组之间完全独立 | 接近线性（但本题 60 s → 秒级后 IO/调度占比上升） | 结果需确定性合并（各线程存局部 top/bottom 再归并） |
| 去掉 `Combination` 里的迭代 `printf` | `Combination` 自身仅 0.35% | 几乎无（重定向后 IO 便宜） | 手册允许删，但**优先级最低** |
| `O(n²) → O(n log n)`（k=2 时按第一维排序 + 扫描） | 算法层总量 6.24×10¹⁰ | 数量级 | 推导易错，必须有 refer 兜底 |

---

## 7. 本机（Windows）没有 perf 时我做了什么（含一次失败的路）

本机是 Windows，没有 Linux perf（也确认过本机没装 WSL）。我试了三条路：

**路线 A：gprof（失败，值得记）**

```powershell
gcc -O2 -pg -fno-inline -o pivot_pg2.exe pivot.c -lm
.\pivot_pg2.exe .\uniformvector-2dim-5h.txt
gprof .\pivot_pg2.exe gmon.out      # → flat profile 是空的（no time propagated）
```

原因：mingw 的 `-pg` 只可靠地埋了 `mcount` 计数，**采样靠 `profil()`，在 64 位 Windows 上不生效**；`-O2` 还会把 `SumDistance` 内联掉。→ **教训：gprof 是"插桩+采样"的老工具，跨平台不可靠；找热点优先 perf。**

**路线 B：插桩计时（成功，拿到可用的实测占比）**

复制一份 `pivot_timed.c`（**算法与输出完全不动**，只在 `SumDistance` 里加三段 `gettimeofday`），`-O2` 跑一次：

```
Using time : 37200.642000 ms
[INSTR] SumDistance calls = 124750
[INSTR] rebuild coords   =     3076.1 ms  ( 8.30 %)
[INSTR] chebyshev sum    =    33952.7 ms  (91.65 %)
[INSTR] malloc           =       17.0 ms  ( 0.05 %)
[INSTR] accounted total  =    37045.8 ms
```

原始输出 [data/hotspot-instrumented-local.txt](data/hotspot-instrumented-local.txt)，插桩源码 [data/pivot_timed.c](data/pivot_timed.c)；这次运行 `result.txt` 仍与 refer 一致（`924858624d0290f1`），**证明插桩没有改变行为**。

说明什么：

1. 调用 **124750 次** = `C(500,2)`，与"枚举所有组合"完全吻合；
2. **91.65% 在切比雪夫双重循环**，8.30% 在重建坐标；
3. `malloc` 只占 **0.05%**——12 万次 8 KB 分配不是瓶颈（perf 的 `page-faults = 154` 从另一侧印证）；
4. 三段合计 99.6%，与 perf 采样的 99.61% 吻合。

它给不出什么：插桩只能测"我事先想到要测的段落"，**测不出 IPC/cache/branch，也发现不了我没想到的热点**。这正是必须上服务器用 perf 的原因。

**路线 C：ETW 采样（备选，未采用）**：`wpr -start CPU` → 跑 → `wpr -stop` → `xperf -i trace.etl -a dumper -profile` 能给函数级采样，但 mingw 产物没有 PDB，`xperf` 只有"模块+偏移"，价值有限。
