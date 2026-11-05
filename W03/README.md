# W03 · 蔡源培（cyp）

**本周作业：跑通赛题 → 编译优化 → perf 看热点**

> 说明文件按"做了什么 + 学到了什么 + 证据在哪"组织。所有数字都有对应的原始日志，链接写在各节里。

---

## 0. 结论速览

| 环节 | 状态 | 关键结果 |
|---|---|---|
| 1. 跑通赛题 | ✅ 完成（本机 Windows/gcc 16.2 + 服务器 hzcu-hpct/gcc 12.3 各跑通一遍） | `result.txt` 与 `refer-2dim-5h.txt` **2000 行逐字节一致**（服务器上每一档、每一次都复核过） |
| 2. 最小单位 | ✅ 完成 | 环境 → 源码 → 编译 → 链接 → 运行 → 输出，每一步都有验证命令 |
| 3. 编译优化实验 | ✅ 完成（本机每档 3 次；服务器每档 2 次） | `-O0 → -O1` 就有约 9 倍，见 [compile-opts.md](compile-opts.md)；换选项后结果不变（18/18 + 服务器全部 SAME） |
| 4. perf | ✅ 完成（hzcu-hpct 实测 stat / record / report / annotate） | `SumDistance` 自身 **99.55%**；**IPC 6.27**、L1 命中 99.9958%、branch miss 0.040% → **计算受限**，见 [perf.md](perf.md) 与 [data/perf-measured.md](data/perf-measured.md) |
| 5. 说明文件 | ✅ 本文件 | 已在 `W03/` |

**一句话结论**：这道赛题 99% 的时间花在 `SumDistance()` 上——它每评估一组 pivots 就要重算 `n × k` 个重建坐标，再算 `n × n` 个点对的切比雪夫距离；总组合数 `C(n,k) = C(500,2) = 124750` 组，内层累计约 **6.24 × 10¹⁰** 次距离比较。所以"换编译选项"只是常数级改善，真正的加速必须从算法和数据复用上做（W04 再说）。

---

## 1. 我亲手做了什么（命令级记录）

完整逐条记录见 [run-log.md](run-log.md)，下面是骨架：

```bash
# 环境：先查有没有，再决定装不装
which gcc && gcc --version          # 已有 gcc，不需要装
lscpu | head -20                    # 机器什么规模
free -h                             # 内存够不够（本题 malloc 只有几十 KB，肯定够）

# 拿源码
tar -xf pivot.tar                   # 得到 pivot/ 目录：pivot.c + 输入 + refer

# 编译（先用参考命令，不加优化）
gcc pivot.c -lm -o pivot

# 运行（单次几十秒~几分钟，挂后台别让 SSH 断了）
nohup ./pivot uniformvector-2dim-5h.txt > run.log 2>&1 &

# 先对再快：结果和基准文件比对
diff result.txt refer-2dim-5h.txt && echo SAME
```

我本机没有 Linux，`perf` 不存在（见 [perf.md](perf.md) 第 1 节），所以 1~3 项先在 Windows + w64devkit gcc 16.2.0 上跑通并测数据；第 4 项 perf 的采集方案、脚本、记录表按 `hzcu-hpct`（Ubuntu 22.04 + Slurm，128 核）写死，登录后一条命令即可产出数据。

---

## 2. 我学到了什么

### 2.1 "跑通"不是一个动作，是一条链

以前觉得"跑通 = 程序没报错"。这次按 `环境 → 源码 → 编译 → 链接 → 运行 → 输出` 拆开，才发现每一环都能独立出错，而且**每一环都可以单独验证**：

- 环境错：`gcc` 没装 / 版本不对 → `gcc --version` 立刻暴露；
- 编译错：语法、头文件 → `-Wall` 加警告、逐个修；
- 链接错：`-lm` 漏了 → `undefined reference to pow/sqrt`，这是本题最常见的坑；
- 运行错：输入文件路径不对 → 程序自己打印 `uniformvector-2dim-5h.txt file not found.`；
- 输出错：算错了、或者格式不对 → `diff result.txt refer-*` 立刻判定。

细节见 [minimal-chain.md](minimal-chain.md)。

### 2.2 编译优化是"免费的加速"，但上限很明显

同一份代码，只改 `-O0 → -O1/-O2`，服务器上 500 s → 60.6 s（8.25 倍）、本机 302 s → 33 s（9.16 倍）——因为编译器会做寄存器分配、循环不变量外提、`pow(x,2) → x*x`、内联。但代价是**它一个字节的算法都不会替你改**：`C(n,k) × n²` 还是 `C(n,k) × n²`。而且在 `-O1` 之上继续加档，收益掉到 ±10% 量级，`-march=native` 在本题甚至零收益/负收益（原因见 [compile-opts.md](compile-opts.md) 4.2、[perf.md](perf.md) 4.4）。**所以"调编译选项"只能算第一次白捡，之后必须动算法和并行。**

### 2.3 "先对再快"是纪律，不是口号

编译选项一换，浮点求和顺序可能变，数值就可能有末位差异。本周每次换选项我都重跑并 `diff`，确认 2000 行输出没变——**加速比只有在结果仍然正确时才有意义**。

### 2.4 perf 的价值：把"我觉得慢在 SumDistance"变成"数据说 99.x% 在这里"

靠读代码猜热点，容易猜错（尤其是 `malloc/free`、排序、IO 这些"看起来贵"的地方）。perf 的采样 + 硬件计数器把这件事变成可量化的：热点函数占比、IPC、cache/branch miss 率，直接告诉你"该往哪个方向改"——是算得太多（计算密集），还是内存喂不饱（访存密集）。详见 [perf.md](perf.md)。

---

## 3. 目录

```
W03/
├── README.md             # 本文件：结论 + 收获
├── run-log.md            # 亲手敲过的命令，逐条 + 每步在干什么
├── minimal-chain.md      # "最小单位"：源码→结果最少几步，每步怎么确认
├── compile-opts.md       # 编译优化实验：服务器 + 本机两张表、加速比、diff 证据
├── perf.md               # perf：是什么 / 三件套 / 采集方案 / 实测数据与解读 / 改法清单
├── scripts/
│   ├── run-o-levels.sh   # 一键跑 -O0..-O3(+native)，每档 N 次，自动计时+逐次 diff
│   ├── perf-stat.sh      # perf stat 采集 + 自动算 IPC / miss 率
│   ├── perf-record.sh    # perf record + report + annotate
│   └── server-run-all.sh # 服务器上一键跑完：编译→计时→校验→perf
└── data/
    ├── perf-measured.md            # ★ perf 采集记录表（hzcu-hpct 实测，已填）
    ├── perf-template.md            # 同一张表的空模板（下次采集直接用）
    ├── server-perf/                # perf stat / report / annotate 原文
    ├── server-timing.txt           # 服务器 6 档计时原始日志
    ├── server-verify.txt           # 服务器 12 次运行的逐次 diff 清单（checked=12，全 SAME）
    ├── server-env.txt / server-build.txt
    ├── bench-local.txt             # 本机 6 档 × 3 次 原始日志
    ├── hotspot-instrumented-local.txt  # 本机插桩实测热点原始输出
    └── pivot_timed.c               # 插桩版源码（算法不动，只加计时；自证 99.6%）
```

---

## 4. 下周要做

1. 按 [perf.md](perf.md) 第 6 节的改法清单动手改代码（W04 任务）：**先把重建坐标改成预计算距离矩阵 + 只算 `i<j`**，每一步都 `diff refer` 保正确；
2. 用 OpenMP 把 124750 组组合铺到 128 核，解决"结果合并要确定性"的问题（各线程存局部 top/bottom 再归并）；
3. 改完再用同一套 perf 命令复测，对比 `IPC / cycles` 与 `SumDistance` 占比，验证"改法是否真的打在瓶颈上"；
4. 复盘一条本周学到的纪律：**所有加速比都必须以 diff 通过为前提**。

---

## 5. 附：本次实测的关键数字（便于分享时直接引用）

| 指标 | 值 | 来源 |
|---|---|---|
| 服务器 `-O0` / `-O2` | 500.47 s / 60.65 s（**8.25x**） | `-O2` 最快档 |
| 本机 `-O0` / `-O1` | 302.58 s / 33.04 s（**9.16x**） | `-O1` 最快档 |
| 组合数 | 124750 = C(500,2) | 插桩计数器 |
| 内层迭代总量 | 6.2375×10¹⁰ | 6.2375e10 = 124750×500×500×2 |
| 热点函数占比 | `SumDistance` **99.55%**（perf）/ **99.6%**（插桩） | 两种方法互证 |
| IPC | **6.27** | 计算受限 |
| L1 命中率 | 99.9958% | 访存不是瓶颈 |
| 分支失败率 | 0.040% | 控制流不是瓶颈 |
| 每内层迭代 | 2.49 cycles / 15.6 条指令 | 依赖链延迟是瓶颈 |
