# perf 采集记录表（已填，hzcu-hpct 实测）

> 采集人：cyp ｜ 采集日期：2026-10-30 ｜ 机器：`hzcu-hpct`（`ssh -p 9446 cyp@10.61.190.8`）

## 一、采集方式

| 项目 | 内容 |
|---|---|
| 命令（stat） | `perf stat -r 3 -e task-clock,cycles,instructions,cache-references,cache-misses,branch-instructions,branch-misses,context-switches,page-faults,minor-faults,major-faults,L1-dcache-loads,L1-dcache-load-misses,LLC-loads,LLC-load-misses taskset -c 8 ./pivot_O2 uniformvector-2dim-5h.txt` |
| 命令（record） | `perf record -F 999 -g -o perf.data -- taskset -c 8 ./pivot_O2 uniformvector-2dim-5h.txt` |
| 命令（report） | `perf report -i perf.data --stdio --sort symbol --percent-limit 0.5` |
| 命令（annotate） | `perf annotate -i perf.data --stdio -s SumDistance` |
| 参数含义 | `-r 3` 重复 3 次；`-e` 选计数器；`-F 999` 采样 999 Hz；`-g` 记调用栈；`taskset -c 8` 绑核 |
| 硬件环境 | Intel Xeon Gold 6430（32C/64T × 2 socket = 128 线程，L3 120 MiB，内存 503 GiB） |
| 软件环境 | Ubuntu 22.04 ｜ kernel `5.15.0-191-generic` ｜ gcc 12.3.0 ｜ perf 5.15.209 ｜ `perf_event_paranoid = -1` |
| 编译方式 | `gcc -O2 -g -fno-omit-frame-pointer -o pivot_O2 pivot.c -lm` |
| 输入 | `uniformvector-2dim-5h.txt`（dim=2, n=500, k=2） |
| 采集次数 | stat：`-r 3`（3 次均值）｜ record：1 次，999 Hz × 59.9 s ≈ **60016 个样本**，Lost Samples = 0 |
| 干扰控制 | 绑核 `taskset -c 8`；机器为共享机（当时约 93 GB 内存被他人占用），比率类指标不受影响 |

## 二、`perf stat` 原始数据（3 次均值 ± 标准差）

| 事件 | 值 | 波动 |
|---|---|---|
| task-clock (msec) | 59,890.99 | ± 0.17% |
| cycles | 155,495,397,364 | ± 0.17% |
| instructions | 975,289,914,930 | ± 0.01% |
| cache-references | 852,671 | ± 16.47% |
| cache-misses | 260,451 | ± 5.80% |
| branch-instructions | 157,338,268,035 | ± 0.00% |
| branch-misses | 63,313,307 | ± 0.03% |
| context-switches | 157 | ± 1.12% |
| page-faults | 154（全 minor，major = 0） | ± 0.22% |
| L1-dcache-loads | 125,847,186,364 | ± 0.00% |
| L1-dcache-load-misses | 5,312,177 | ± 1.00% |
| LLC-loads | 256,546 | ± 13.02% |
| LLC-load-misses | 84,004 | ± 2.04% |
| time elapsed (s) | 59.980 ± 0.102 | ± 0.17% |

## 三、派生指标与判定

| 指标 | 值 | 判据 | 结论 |
|---|---|---|---|
| IPC = instructions/cycles | **6.27** | >1.5 计算受限 ／ <0.8 访存受限 | 计算受限，流水线被打满 |
| 有效频率 = cycles/task-clock | 2.596 GHz | — | 未跑满 3.4 GHz 睿频（共享机 + 全核负载） |
| L1 命中率 | 99.9958% | 高 | 工作集 `n·k·8B = 8 KB` 全在 L1 |
| LLC 访问量 | 4.28 K/s（25.6 万次/60 s） | — | 内存层次基本没参与 |
| cache miss 率 | 31.58%（基数仅 85 万次） | 必须结合基数看 | 绝对值 26 万次，摊 60 s 可忽略 |
| branch miss 率 | **0.040%** | >5% 控制流不友好 | 控制流极友好（`?:` 编译成 `maxsd`，无分支） |
| 每内层迭代 cycles | 2.49（155.50G / 6.2375e10） | — | 每 2.49 周期完成一次"2×fabs+2×max+1×add" |
| 每内层迭代指令 | 15.6 条 | — | 地址计算与循环开销占比不小 |

**总体判定：计算密集（更准确：标量浮点 + 依赖链受限），不是访存密集。**

依据（写给下次组会分享）：

> L1 命中率 99.9958%、LLC 只有 4.28 K/s 的访问量，说明 8 KB 的 `rebuiltCoord` 全程待在 L1，
> 内存层次根本没参与；IPC 6.27 说明 CPU 大部分时间在执行而不是在等；
> branch miss 率 0.040% 说明控制流不是瓶颈。
> 但内层仍有 2.49 cycle/迭代，且 annotate 显示 `maxsd`（3~4 cycle 延迟）与 `addsd`
> （3~4 cycle 延迟）串成两条依赖链 → 瓶颈是**浮点依赖链延迟**，不是带宽、不是分支。
> 所以优化方向是"减少运算量 + 拆累加器打断依赖 + 向量化 + 并行"，而不是"改善数据布局"。
> 注意 cache-misses 的 31.58% 是个陷阱：基数只有 85 万次，绝对值 26 万次在 60 s 里毫无意义。

## 四、`perf report` 热点（60016 样本，Lost = 0）

| 排名 | 符号 | Children | Self | 说明 |
|---|---|---|---|---|
| 1 | `SumDistance` | 99.61% | **99.55%** | 唯一热点：重建坐标 + `n²k` 切比雪夫求和 |
| 2 | `Combination` | 99.98% | **0.35%** | 递归枚举 + 排序 + 迭代 `printf`，自身开销可忽略 |
| 3 | `main` | 99.98% | 0.00% | 只在启动与收尾 |

## 五、`perf annotate` 行级热点（`SumDistance` 内层循环）

| cycles 占比 | 指令 | 解读 |
|---|---|---|
| 19.27% | `jne 19a0` | 内层循环回边（指令流汇聚点） |
| 18.00% | `mov %r11,%rdx` | j 循环起点重置指针（skid：吸收了上一轮 `addsd` 的等待） |
| 17.52% | `mov %edx,%r8d` | 复位 ki 计数 |
| 16.45% | `maxsd %xmm1,%xmm0` | 切比雪夫核心 `dis>chebyshev?dis:chebyshev` → 无分支 `maxsd` |
| 10.34% | `movsd (%rdx),%xmm0` | 读 `rebuiltCoord[j*k+ki]` |
| 8.28% | `jmp 1988` | 循环结构跳转 |
| 6.31% | `addsd %xmm1,%xmm3` | `chebyshevSum += chebyshev`：唯一累加器 → 串行依赖 |
| 2.99% | `andpd %xmm2,%xmm0` | `fabs` 的位掩码实现 |

**关键结论**：全程 `movsd/maxsd/addsd/andpd`（标量 SSE2，一次一个 double），**没有一条打包指令**——向量化机会完全没被利用；同时 `maxsd` 与 `addsd` 两条链串行。

## 六、结论与下一步

1. **热点确认**：`SumDistance` 自身 99.55%（与本机插桩的 99.6% 交叉验证一致）；
2. **数据支持的优化方向**：预计算距离矩阵（消 `pow/sqrt`）、只算 `i<j` 再 ×2、拆累加器打断依赖链、向量化打包、OpenMP 遍历组合；
3. **需要复核**：改浮点求和顺序后必须重新 `diff refer`；并行合并需保证输出顺序确定性。
