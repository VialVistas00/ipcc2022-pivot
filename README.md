# ACM China IPCC 2022 · pivot 题解与优化

2022 年 ACM 中国（CCPC）高性能计算挑战赛（IPCC）pivot 赛题的完整工作记录：从原始程序跑通、编译选项实验、perf 热点分析，到距离矩阵预计算与 OpenMP 并行优化。

- **题目参数**：`dim = 2`，`n = 500`，`k = 2`，组合数 `C(500,2) = 124750`
- **输出要求**：目标函数最大 / 最小的各 1000 组 pivots，必须与 `refer-2dim-5h.txt` **逐字节一致**
- **最终结果**：单线程 **2.11×**（三次中位数），20 线程 **21.0×**；所有线程数输出哈希相同

---

## 目录

```
.
├── pivot/                  # 原始赛题材料
│   ├── pivot.c             # 参考程序（未修改）
│   ├── uniformvector-2dim-5h.txt
│   └── refer-2dim-5h.txt   # 2000 行参考输出
├── W03/                    # 第一周：跑通 + 编译优化 + perf
│   ├── README.md           # 结论与收获
│   ├── run-log.md          # 命令级记录
│   ├── minimal-chain.md    # 最小可运行链路
│   ├── compile-opts.md     # -O0..-O3 / -march=native 实验
│   ├── perf.md             # perf 方法与结果解读
│   ├── scripts/            # 一键计时、perf stat/record
│   └── data/               # 原始日志、perf 报告、服务器环境
├── W04/                    # 第二周：算法复用 + OpenMP
│   ├── README.md           # 优化设计与验证
│   ├── src/pivot_opt.c     # 优化版源码
│   ├── iteration.md        # v0/v1/v2 迭代与中位数
│   ├── understanding.md    # 一页理解：复杂度与优化取舍
│   ├── flame.svg           # perf 热点火焰图
│   ├── scripts/            # 批量运行、结果校验、火焰图生成
│   └── data/               # 计时、校验、perf report/annotate 原文
├── Makefile
└── README.md
```

---

## 结论速览

| 阶段 | 配置 | 用时 | 相对基线 |
|---|---|---|---|
| W03 基线 | `pivot.c -O2`，1 线程 | 37,173 ms（中位数） | 1.00× |
| W04 v1 | 距离矩阵 + `k=2` 特化，1 线程 | 17,605 ms | **2.11×** |
| W04 v2 | 同上 + OpenMP，20 线程 | 1,767 ms | **21.0×** |
| 参考 | `-O0`，1 线程 | 302,580 ms（本机单次） | 0.12× |

> 上表使用三次运行的中位数，比 README 中单次对比的 2.42× / 24.6× 更保守。本机为 i7-13650HX（14C/20T）/ Windows 11 / gcc 16.2.0；服务器数据见 `W03/data/`。

正确性：1 / 2 / 4 / 8 / 20 线程全部与参考输出一致，SHA-256 均为
`924858624d0290f145864ebe8b0cd094a1ddfc05935c952c3c95f63169db6a21`（CRLF 归一化后）。

### 关键设计

1. **预计算距离矩阵**：每个 pivot 到全部点的距离只与自身坐标有关，先算成 `n×n` 列主序矩阵（约 2 MB），评估组合时退化为查表。
2. **`k=2` 内层特化**：直接持有两行距离指针，去掉内层乘法寻址。
3. **确定性并行**：组合按字典序枚举并携带 rank，每个组合写入自己的槽位，`schedule(dynamic,1)` 按第一个 pivot 划分，无锁且结果与线程数无关。
4. **稳定等价排序**：按 `(目标值, rank)` 排序取前 1000，复现参考程序插入法的并列顺序。
5. **保留浮点求和顺序**：不做 `(i,j)` 对称减半、多累加器等会改变末位结果的优化。

细节见 [W04/README.md](W04/README.md)、[W04/iteration.md](W04/iteration.md) 和 [W04/understanding.md](W04/understanding.md)。

---

## 快速开始

依赖：`gcc`（支持 OpenMP）、`make`、`python3`。

```bash
make                 # 构建 build/pivot 与 build/pivot_opt
make run-baseline    # 运行原始程序，写出 result.txt（约 40 s）
make run-opt         # 运行优化版，默认 4 线程
make verify          # 校验 result.txt 与参考输出
```

指定线程数：

```bash
make run-opt OMP_NUM_THREADS=20
# 或直接运行
gcc -O2 -fopenmp -o build/pivot_opt W04/src/pivot_opt.c -lm
OMP_NUM_THREADS=20 ./build/pivot_opt pivot/uniformvector-2dim-5h.txt
```

重新生成火焰图：

```bash
make flame           # 读取 W04/data/perf-*.txt，输出 W04/flame.svg
```

---

## 数据说明

- `pivot/` 下三个文件为赛题原始材料，未做修改。
- `W03/data/server-perf/` 为服务器 `hzcu-hpct`（Xeon Gold 6430，perf 5.15.209）上的 `perf stat` / `report` / `annotate` 原文。
- `W04/flame.svg` 由 `perf report` 与 `perf annotate` 的聚合百分比重建：原始 `perf.data` 未入库，因此宽度表示采样占比，而不是逐样本栈回放。生成脚本见 [W04/scripts/make_flame_svg.py](W04/scripts/make_flame_svg.py)。
- 所有加速比均以 `result.txt` 与 `refer-2dim-5h.txt` 一致为前提；校验脚本见 [W04/scripts/verify_result.py](W04/scripts/verify_result.py)。

---

## 环境

| 项 | 本机 | 服务器 |
|---|---|---|
| CPU | i7-13650HX（14C/20T） | Xeon Gold 6430（128 逻辑核） |
| OS | Windows 11 + Git Bash | Ubuntu 22.04 + Slurm |
| 编译器 | gcc 16.2.0（w64devkit） | gcc 12.3.0 |
| 工具 | 插桩计时 | perf 5.15.209 |

---

本仓库用于课程作业与竞赛复盘。赛题材料版权归 ACM China IPCC 组委会所有。
