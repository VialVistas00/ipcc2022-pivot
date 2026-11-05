#!/usr/bin/env bash
# ============================================================
# 在 hzcu-hpct 上一键跑完 W03 作业：编译优化实验 + perf stat + perf record/report
# 用法：  bash server-run-all.sh            （当前目录需有 pivot.c / 输入 / refer）
# 产物：  results/  （日志 + 每次的 result.txt + perf 报告）
# ============================================================
set -u
IN=uniformvector-2dim-5h.txt
REF=refer-2dim-5h.txt
REP=${REP:-3}
OUT=results
mkdir -p "$OUT"

echo "=== 0. 环境 ===" | tee "$OUT/env.txt"
{ hostname; uname -a; gcc --version | head -1; nproc; free -h | head -2; lscpu | grep -E 'Model name|MHz|L1d|L2|L3'; } >> "$OUT/env.txt" 2>&1
perf --version >> "$OUT/env.txt" 2>&1 || echo "perf NOT FOUND -> sudo apt install linux-tools-$(uname -r)" >> "$OUT/env.txt"
echo "perf_event_paranoid=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null)" >> "$OUT/env.txt"
cat "$OUT/env.txt"

echo "=== 1. 编译各级优化 ===" | tee "$OUT/build.txt"
for L in O0 O1 O2 O3; do
  gcc -$L -g -fno-omit-frame-pointer -o "pivot_$L" pivot.c -lm 2>>"$OUT/build.txt" && echo "OK   pivot_$L" | tee -a "$OUT/build.txt"
done
gcc -O2 -march=native -g -fno-omit-frame-pointer -o pivot_O2native pivot.c -lm 2>>"$OUT/build.txt" && echo "OK   pivot_O2native" | tee -a "$OUT/build.txt"
gcc -O3 -march=native -g -fno-omit-frame-pointer -o pivot_O3native pivot.c -lm 2>>"$OUT/build.txt" && echo "OK   pivot_O3native" | tee -a "$OUT/build.txt"

echo "=== 2. 计时（每档 $REP 次） ===" | tee "$OUT/timing.txt"
printf '%-12s %-4s %10s %14s\n' LEVEL RUN WALL_S USING_TIME_MS | tee -a "$OUT/timing.txt"
for L in O0 O1 O2 O3 O2native O3native; do
  BIN=./pivot_$L
  [ -x "$BIN" ] || continue
  for r in $(seq 1 "$REP"); do
    d="$OUT/run/$L/r$r"; mkdir -p "$d"
    /usr/bin/time -f '%e' -o "$d/wall.txt" taskset -c 0 "$BIN" "$IN" > "$d/stdout.txt" 2>&1
    w=$(cat "$d/wall.txt" | tail -1)
    s=$(grep -o 'Using time : [0-9.]*' "$d/stdout.txt" | tail -1 | awk '{print $4}')
    printf '%-12s %-4s %10s %14s\n' "$L" "r$r" "$w" "$s" | tee -a "$OUT/timing.txt"
    cp result.txt "$d/result.txt" 2>/dev/null
    if diff -q result.txt "$REF" >/dev/null; then echo "  result SAME" >> "$OUT/timing.txt"; else echo "  result DIFF !!" >> "$OUT/timing.txt"; fi
  done
done

echo "=== 3. perf stat ===" | tee "$OUT/perf-stat.txt"
perf stat -r "$REP" \
  -e task-clock,cycles,instructions,cache-references,cache-misses,branch-instructions,branch-misses,context-switches,page-faults \
  taskset -c 0 ./pivot_O2 "$IN" > "$OUT/perf-stat-stdout.log" 2>> "$OUT/perf-stat.txt"
cat "$OUT/perf-stat.txt"

echo "=== 4. perf record + report ===" | tee "$OUT/perf-record.txt"
perf record -F 999 -g -o "$OUT/perf.data" -- taskset -c 0 ./pivot_O2 "$IN" > "$OUT/perf-record-stdout.log" 2>> "$OUT/perf-record.txt"
perf report -i "$OUT/perf.data" --stdio --sort symbol --percent-limit 0.5 > "$OUT/perf-report.txt" 2>/dev/null
perf annotate -i "$OUT/perf.data" --stdio -s SumDistance > "$OUT/perf-annotate-SumDistance.txt" 2>/dev/null
head -40 "$OUT/perf-report.txt"

echo "=== 5. 校验汇总 ===" | tee "$OUT/verify.txt"
for f in "$OUT"/run/*/*/result.txt; do
  if diff -q "$f" "$REF" >/dev/null; then echo "SAME $f" >> "$OUT/verify.txt"; else echo "DIFF $f" >> "$OUT/verify.txt"; fi
done
cat "$OUT/verify.txt"
echo "全部产物在 $OUT/"
