# W04 迭代记录：pivot 优化

> 计时口径：程序打印的 `Using time`（ms），本机 i7-13650HX / Windows 11 / gcc 16.2.0。
> `diff` 列：`result.txt` 与 `refer-2dim-5h.txt` 做 CRLF 归一化后比较 SHA-256，全部一致。
> 所有版本都保留参考程序的浮点求和顺序，没有为了快而改变输出。

| 版本 | commit | 改了什么 | 耗时（3 次中位数） | 相对上一版 | diff |
|---|---|---|---|---|---|
| v0-baseline | [`v0-baseline`](https://github.com/VialVistas00/ipcc2022-pivot/tree/v0-baseline) | 原始 `pivot.c -O2`，单线程 | **37,173 ms**（36,825 / 37,719 / 37,173） | — | ok |
| v1 | [`747dca6`](https://github.com/VialVistas00/ipcc2022-pivot/commit/747dca61c2f72df9d72bb5f1c5990ef72ebab1e0) | 预计算 `n×n` 距离矩阵 + `k=2` 内层特化，1 线程 | **17,605 ms**（17,605 / 17,562 / 17,644） | 2.11× | ok |
| v2 | [`747dca6`](https://github.com/VialVistas00/ipcc2022-pivot/commit/747dca61c2f72df9d72bb5f1c5990ef72ebab1e0) | 同一 commit 打开 OpenMP，20 线程 | **1,767 ms**（1,736 / 1,767 / 1,848） | 21.0× vs v0；9.96× vs v1 | ok |

## 说明

- v1 和 v2 是同一个代码 commit 的两种运行配置。W04 的距离矩阵、`k=2` 特化和 OpenMP 一次性提交，所以没有为了凑版本号把它拆成两个 commit；表中按运行配置分行，方便看“单线程优化”和“并行收益”各占多少。
- W04 `README.md` 里的 2.42× / 24.6× 用的是 **单次** baseline 41,555 ms 与最终验证跑 17,154 / 1,689 ms；本表用 3 次中位数，数字更保守（2.11× / 21.0×）。两套原始记录分别是 [data/bench-opt-local.txt](data/bench-opt-local.txt) 和 W03 的 [bench-local.txt](https://github.com/VialVistas00/ipcc2022-pivot/blob/main/W03/data/bench-local.txt)。
- 20 线程中位数 1,767 ms 与最终验证跑 1,689 ms 的差异约 4.6%，来自共享机器负载和混合 P/E 核调度；方向性结论不受影响。

## 数据文件

- [data/bench-opt-local.txt](data/bench-opt-local.txt)：baseline、1 线程 / 20 线程重复 3 次、1 / 2 / 4 / 8 / 20 线程最终验证；
- [data/verify-opt-local.txt](data/verify-opt-local.txt)：各线程数的 SHA-256 与 `SAME` 记录；
- [data/stdout-1t.txt](data/stdout-1t.txt)、[data/stdout-20t.txt](data/stdout-20t.txt)：代表性输出与时间构成。
