# W04 · 蔡源培（cyp）

**本周任务：预计算距离矩阵 + OpenMP 并行**

> 延续 W03 的纪律：任何加速都必须以 `result.txt` 与 `refer-2dim-5h.txt` 逐字节一致为前提。

**新版任务材料**：[flame.svg](flame.svg)（perf 热点火焰图）、[iteration.md](iteration.md)（版本迭代表）、[understanding.md](understanding.md)（一页理解）。完整代码、脚本和原始数据仍保留在本目录，便于复现。火焰图可用 `python scripts/make_flame_svg.py` 重新生成。

---

## 0. 结论速览

| 项 | 结果 |
|---|---|
| 正确性 | 1 / 2 / 4 / 8 / 20 线程全部 `SAME`，SHA-256 = `924858624d0290f1...` |
| 单线程 | 41.56 s → 17.15 s（**2.42×**），来自距离矩阵复用 + 去掉重复重建 |
| 20 线程 | 41.56 s → 1.69 s（**24.6×**）；相对优化版单线程 **10.15×** |
| 相对 `-O0` | 302.58 s → 1.69 s（约 **179×**） |
| 关键设计 | 枚举带 rank、每个组合写自己的槽位：无锁、确定性；排序用 `(目标值, rank)` 复现参考插入排序的并列顺序 |

> 本机：i7-13650HX（14C/20T）/ Windows 11 / gcc 16.2.0；基线为 W03 的 `pivot.c -O2` 单线程。

---

## 1. 改了什么

源码：[src/pivot_opt.c](src/pivot_opt.c)

### 1.1 预计算距离矩阵

原程序每评估一组 pivots，都要把 `n × k` 个重建坐标从头算一遍（每个坐标 `dim` 次 `pow` + 1 次 `sqrt`）。这些距离与"这一组其它 pivot 是谁"无关，因此只算一次：

```
distMat[p*n + x] = sqrt(Σ_j pow(coord[p][j] - coord[x][j], 2))
```

采用 **列主序**（`p` 为行），使某个 pivot 的距离向量在内存中连续。`n = 500` 时矩阵仅 2 MB，全部落在缓存里。重建坐标退化为查表；`k == 2` 时直接使用 `distMat + piv[0]*n` 和 `distMat + piv[1]*n` 两个指针，内层不再做乘法寻址。

### 1.2 枚举与并行

组合按字典序递归枚举，递归时携带 **组合 rank**：

- 每个叶子组合的 rank 唯一，直接写入 `sums[rank]` 和 `combos[rank*k ...]`；
- 顶层对第一个 pivot 做 `#pragma omp for schedule(dynamic, 1)`，各线程互不重叠；
- 每个线程只分配一份 `piv` / `rebuilt` 临时缓冲，避免 12 万次 `malloc`。

这样并行不需要锁、不需要原子操作，而且**结果与线程数无关**。

### 1.3 选择与排序

参考程序用插入法维护 top/bottom 1000，值相等时先枚举到的组合排在前。优化版把全部 `C(500,2) = 124750` 个目标值一次性算出，再按：

- max：目标值降序，相等时 **rank 升序**；
- min：目标值升序，相等时 **rank 升序**；

排序取前 1000。这与参考的稳定插入行为完全等价。候选数组约 2 MB，排序开销 20–30 ms，可忽略。

### 1.4 为什么保留参考的求和顺序

预计算只复用**相同的表达式**，每个组合内部仍按 `i = 0..n-1`、`j = 0..n-1` 的顺序累加；对角线点对贡献恰好 `+0.0`，因此跳过不改变结果。**没有**做以下两种会改变浮点求和顺序的优化：

- `(i,j)` 与 `(j,i)` 对称只算一半再 ×2；
- 拆多个累加器 / 重排循环。

原因是浮点加法不满足结合律，末位差异可能改变第 1000 名附近的并列顺序。这一步留给后续：先跑 `diff`，确认仍与 refer 一致再启用。

---

## 2. 正确性验证

每次运行后对 `result.txt` 做 CRLF 归一化再比 SHA-256，脚本见 [scripts/verify_result.py](scripts/verify_result.py)。

| 线程数 | Using time | 结果 |
|---|---|---|
| 1 | 17153.6 ms | SAME |
| 2 | 9409.2 ms | SAME |
| 4 | 5269.4 ms | SAME |
| 8 | 3502.1 ms | SAME |
| 20 | 1689.5 ms | SAME |

原始清单：[data/verify-opt-local.txt](data/verify-opt-local.txt)。所有线程数的哈希均为 `924858624d0290f145864ebe8b0cd094a1ddfc05935c952c3c95f63169db6a21`。

---

## 3. 性能数据（本机）

原始日志：[data/bench-opt-local.txt](data/bench-opt-local.txt)

| 配置 | 线程数 | Using time (ms) | 相对基线 | 相对优化版单线程 |
|---|---|---|---|---|
| `pivot.c -O2` | 1 | 41555 | 1.00× | — |
| `pivot_opt -O2 -fopenmp` | 1 | 17154 | 2.42× | 1.00× |
| 同上 | 2 | 9409 | 4.42× | 1.82× |
| 同上 | 4 | 5269 | 7.89× | 3.26× |
| 同上 | 8 | 3502 | 11.87× | 4.90× |
| 同上 | 20 | 1689 | **24.60×** | **10.15×** |

稳定性：1 线程 3 次均值 17604 ms（17562–17644）；20 线程 3 次均值 1784 ms（1736–1848），波动约 ±3%。

**并行效率**：20 个逻辑线程拿到 10.15×，约 51%。机器是 P 核 + E 核的混合架构，且 20 线程包含超线程；真实服务器（128 个物理线程）上预期更高。

时间构成（20 线程）：`read 1.6 ms / dist 6.1 ms / enum 1694.0 ms / select 27.3 ms`——**枚举仍占 98%**，排序与预处理都不是瓶颈。

---

## 4. 复现方式

```bash
# 本机（Windows / Git Bash）
gcc -O2 -fopenmp -o pivot_opt.exe pivot_opt.c -lm
OMP_NUM_THREADS=20 ./pivot_opt.exe uniformvector-2dim-5h.txt
python scripts/verify_result.py result.txt refer-2dim-5h.txt

# Linux 服务器：一键跑基线 + 多线程 + 逐次校验
bash scripts/run-opt.sh
REP=5 THREADS="1 8 32 64 128" bash scripts/run-opt.sh
```

当前目录需要：`pivot.c`、`pivot_opt.c`、`uniformvector-2dim-5h.txt`、`refer-2dim-5h.txt`。

---

## 5. 下一步

1. 在 `hzcu-hpct` 上复测 32 / 64 / 128 线程，确认扩展性与确定性归并；
2. 尝试 `(i,j)` 对称减半与多累加器，**每一步都以 `diff refer` 通过为前提**；
3. 用 W03 的同一套 `perf stat / record / annotate` 复测，验证瓶颈是否从依赖链转移到并行调度或内存带宽。
