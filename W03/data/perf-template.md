# perf 采集记录表（服务器上跑完后填这张表）

> 采集位置：`hzcu-hpct`（`ssh -p 9446 cyp@10.61.190.8`）
> 采集人：cyp ｜ 采集日期：____-__-__

## 一、采集方式（必填，这是本次分享的重点）

| 项目 | 内容 |
|---|---|
| 命令（stat） | `perf stat -r 3 -e task-clock,cycles,instructions,cache-references,cache-misses,branch-instructions,branch-misses,context-switches,page-faults taskset -c 0 ./pivot_prof uniformvector-2dim-5h.txt` |
| 命令（record） | `perf record -F 999 -g -o perf.data -- taskset -c 0 ./pivot_prof uniformvector-2dim-5h.txt` |
| 命令（report） | `perf report -i perf.data --stdio --sort symbol --percent-limit 0.5` |
| 参数含义 | `-r 3` 重复 3 次；`-e` 选计数器；`-F 999` 采样 999 Hz；`-g` 记调用栈；`taskset -c 0` 绑核 |
| 硬件环境 | CPU 型号：____ ｜ 核数：128 ｜ 内存：____ |
| 软件环境 | `uname -r` = ____ ｜ `gcc --version` = ____ ｜ `perf --version` = ____ |
| 编译方式 | `gcc -O2 -g -fno-omit-frame-pointer -o pivot_prof pivot.c -lm` |
| 输入 | `uniformvector-2dim-5h.txt`（dim=2, n=500, k=2） |
| 采集次数 | stat：3 次/轮 × 1 轮 ｜ record：1 次（≈4 万样本） |
| 干扰控制 | 绑核 + 无其他重负载；`perf_event_paranoid` = ____ |

## 二、`perf stat` 原始数据

| 事件 | run1 | run2 | run3 | 均值 | 变异系数 |
|---|---|---|---|---|---|
| task-clock (msec) | | | | | |
| cycles | | | | | |
| instructions | | | | | |
| cache-references | | | | | |
| cache-misses | | | | | |
| branch-instructions | | | | | |
| branch-misses | | | | | |
| context-switches | | | | | |
| page-faults | | | | | |

## 三、派生指标与判定

| 指标 | 值 | 判据 | 结论 |
|---|---|---|---|
| IPC = instructions/cycles | | >1.5 计算受限 ／ <0.8 访存受限 | |
| cache miss rate = miss/ref | | 低（<5%）说明工作集在缓存里 | |
| branch miss rate = bm/bi | | 高（>5%）说明控制流不友好 | |
| 总体定性 | | | **计算密集 / 访存密集**：____ |

**依据（自己写 2~3 句）**：

> 例：IPC 为 __，说明每周期退休 __ 条指令，CPU 流水线基本被打满；cache misses 仅 __（占 __%），
> 因为 `rebuiltCoord` 工作集只有 `n*k*8 = 8 KB`，可全部驻留 L1；branch miss 率 __%，
> 因为内层是比较+条件选择（编译成 `maxsd`/`cmov`），几乎没有难预测分支。
> 结论：程序受**浮点运算与串行依赖**限制，不是访存受限 → 优化方向是"减少运算量/向量化/并行"，而不是"提高缓存命中"。

## 四、`perf report` 热点（实测）

| 排名 | 函数/符号 | 采样占比 | 归属（自己代码 / libc） | 说明 |
|---|---|---|---|---|
| 1 | | | | 预期 `SumDistance` |
| 2 | | | | 预期 `Combination` |
| 3 | | | | 预期 `main` 或 libc（malloc/free/printf） |

与预期的差异（如果有）：

## 五、`perf annotate` 行级热点（选做）

| 行号 | 源码 | 占比 | 解读 |
|---|---|---|---|
| | `chebyshev = dis>chebyshev ? dis : chebyshev;` | | 内层比较，n²k 次 |

## 六、结论与下一步

1. 热点确认：____
2. 数据支持的优化方向：____
3. 需要复核的地方：____
