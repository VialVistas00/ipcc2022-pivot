#!/usr/bin/env bash
# perf stat：PMU 计数器采集（判断计算密集 / 访存密集）
# 用法：bash perf-stat.sh [可执行文件] [输入文件]
set -u
BIN=${1:-./pivot_prof}
IN=${2:-uniformvector-2dim-5h.txt}
LOG=perf-stat-$(date +%Y%m%d-%H%M%S).log

echo "### 环境" | tee "$LOG"
echo "host=$(hostname)  kernel=$(uname -r)  gcc=$(gcc -dumpversion)  perf=$(perf --version)" | tee -a "$LOG"
echo "cmd: $BIN $IN" | tee -a "$LOG"
echo "perf_event_paranoid=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null)" | tee -a "$LOG"

# 计数：任务钟、周期、指令、cache、分支、上下文切换、缺页；重复 3 次
perf stat -r 3 \
  -e task-clock,cycles,instructions,cache-references,cache-misses,branch-instructions,branch-misses,context-switches,page-faults \
  taskset -c 0 "$BIN" "$IN" > "stdout-stat.log" 2> "$LOG.stat"
cat "$LOG.stat" | tee -a "$LOG"

echo "--- 派生指标（IPC / miss 率）---" | tee -a "$LOG"
awk '
  /instructions/  && !/branch/ {ins=$1}
  /cycles/        {cyc=$1}
  /cache-misses/  {cm=$1}
  /cache-references/ {cr=$1}
  /branch-misses/ {bm=$1}
  /branch-instructions/ && !/misses/ {bi=$1}
  END {
    gsub(",","",ins); gsub(",","",cyc); gsub(",","",cm); gsub(",","",cr); gsub(",","",bm); gsub(",","",bi);
    if (cyc>0)  printf "IPC                = %.3f\n", ins/cyc;
    if (cr>0)   printf "cache miss rate    = %.3f %%\n", 100*cm/cr;
    if (bi>0)   printf "branch miss rate   = %.3f %%\n", 100*bm/bi;
  }' "$LOG.stat" | tee -a "$LOG"

echo "### 判据：IPC>1.5 且 cache miss 低 → 计算受限；IPC<0.8 或 miss 率高 → 访存受限" | tee -a "$LOG"
echo "log saved: $LOG"
