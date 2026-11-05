#!/usr/bin/env bash
# 编译优化实验：-O0 / -O1 / -O2 / -O3 (+ -march=native)，每档 3 次，自动计时并保存结果
# 用法：  bash run-o-levels.sh
# 前置：  当前目录有 pivot.c 和 uniformvector-2dim-5h.txt
set -u

IN=uniformvector-2dim-5h.txt
REF=refer-2dim-5h.txt
REPEATS=3
LOG=bench-$(date +%Y%m%d-%H%M%S).log

echo "host=$(hostname)  kernel=$(uname -r)  gcc=$(gcc -dumpversion)  cores=$(nproc)" | tee -a "$LOG"
echo "input=$IN  repeats=$REPEATS" | tee -a "$LOG"
printf '%-12s %-6s %12s %12s\n' LEVEL RUN WALL_S SELFTIME_MS | tee -a "$LOG"

for LEVEL in O0 O1 O2 O3; do
  gcc -$LEVEL -o "pivot_$LEVEL" pivot.c -lm || { echo "build $LEVEL failed" | tee -a "$LOG"; continue; }
  for r in $(seq 1 $REPEATS); do
    d="runs/$LEVEL/r$r"; mkdir -p "$d"; cp "pivot_$LEVEL" "$IN" "$d"/
    ( cd "$d" && /usr/bin/time -f '%e' -o wall.txt ./pivot_"$LEVEL" "$IN" > stdout.txt 2>&1 )
    WALL=$(cat "$d/wall.txt")
    SELF=$(grep -o 'Using time : [0-9.]*' "$d/stdout.txt" | tail -1 | awk '{print $4}')
    printf '%-12s %-6s %12s %12s\n' "$LEVEL" "r$r" "$WALL" "$SELF" | tee -a "$LOG"
    mv "$d/result.txt" "$d/result_${LEVEL}_r$r.txt" 2>/dev/null
  done
done

# 同样跑一遍 -march=native 变体
for LEVEL in O2 O3; do
  L="${LEVEL}native"
  gcc -$LEVEL -march=native -o "pivot_$L" pivot.c -lm || continue
  for r in $(seq 1 $REPEATS); do
    d="runs/$L/r$r"; mkdir -p "$d"; cp "pivot_$L" "$IN" "$d"/
    ( cd "$d" && /usr/bin/time -f '%e' -o wall.txt ./pivot_"$L" "$IN" > stdout.txt 2>&1 )
    WALL=$(cat "$d/wall.txt")
    SELF=$(grep -o 'Using time : [0-9.]*' "$d/stdout.txt" | tail -1 | awk '{print $4}')
    printf '%-12s %-6s %12s %12s\n' "$L" "r$r" "$WALL" "$SELF" | tee -a "$LOG"
    mv "$d/result.txt" "$d/result_${L}_r$r.txt" 2>/dev/null
  done
done

# 正确性校验：所有结果都必须和 refer 完全一致
echo "--- diff vs $REF ---" | tee -a "$LOG"
for f in runs/*/*/result_*.txt; do
  if diff -q "$f" "$REF" >/dev/null; then echo "SAME  $f" | tee -a "$LOG"
  else echo "DIFF  $f" | tee -a "$LOG"; fi
done
echo "log saved: $LOG"
