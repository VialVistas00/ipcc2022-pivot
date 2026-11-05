#!/usr/bin/env bash
# perf record + report：找热点函数 / 代码段
# 用法：bash perf-record.sh [可执行文件] [输入文件]
set -u
BIN=${1:-./pivot_prof}
IN=${2:-uniformvector-2dim-5h.txt}
DATA=perf-$(date +%Y%m%d-%H%M%S).data

echo "cmd: perf record -F 999 -g -o $DATA -- taskset -c 0 $BIN $IN"

# 采样：999 Hz，记调用栈
perf record -F 999 -g -o "$DATA" -- taskset -c 0 "$BIN" "$IN" > perf-record-stdout.log 2> perf-record-stderr.log
echo "--- record stderr ---"; cat perf-record-stderr.log

# 文本报告：按函数聚合，只显示 >=0.5% 的
perf report -i "$DATA" --stdio --sort symbol --percent-limit 0.5 > perf-report.txt 2>/dev/null
echo "--- 热点函数（按占比）---"
cat perf-report.txt

# 调用链视角（谁调用了谁）
perf report -i "$DATA" --stdio --sort dso,symbol --call-graph 2>/dev/null | head -40 > perf-report-callgraph.txt || true

# 下钻到函数内部：哪一行最热
perf annotate -i "$DATA" --stdio -s SumDistance > perf-annotate-sumdistance.txt 2>/dev/null || \
  echo "（annotate 需要 -g 编译，且源码在同一目录）"

echo "产物: $DATA / perf-report.txt / perf-annotate-sumdistance.txt"
