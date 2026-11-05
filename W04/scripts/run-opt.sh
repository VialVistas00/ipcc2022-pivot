#!/usr/bin/env bash
# W04: baseline vs pivot_opt (precomputed distance matrix + OpenMP)
# Usage:
#   bash run-opt.sh
#   REP=5 THREADS="1 8 32 64 128" bash run-opt.sh
# Requires in the current directory: pivot.c pivot_opt.c input refer file.
set -u

IN=uniformvector-2dim-5h.txt
REF=refer-2dim-5h.txt
REP=${REP:-3}
THREADS=${THREADS:-"1 2 4 8 16 32 64 128"}
OUT=results
mkdir -p "$OUT"

{
  echo "host=$(hostname) kernel=$(uname -r) gcc=$(gcc -dumpversion) cores=$(nproc)"
  echo "input=$IN repeats=$REP threads=$THREADS"
} | tee "$OUT/env.txt"

gcc -O2 -o "$OUT/pivot_base" pivot.c -lm || { echo "baseline build failed"; exit 1; }
gcc -O2 -fopenmp -o "$OUT/pivot_opt" pivot_opt.c -lm || { echo "opt build failed"; exit 1; }

echo "=== baseline (single thread) ===" | tee "$OUT/timing.txt"
/usr/bin/time -f '%e' -o "$OUT/base_wall.txt" "$OUT/pivot_base" "$IN" > "$OUT/base_stdout.txt" 2>&1
cp result.txt "$OUT/base_result.txt"
echo "threads=1 wall=$(tail -1 "$OUT/base_wall.txt") $(grep 'Using time' "$OUT/base_stdout.txt" | tail -1)" | tee -a "$OUT/timing.txt"

echo "=== pivot_opt ===" | tee -a "$OUT/timing.txt"
for t in $THREADS; do
  for r in $(seq 1 "$REP"); do
    d="$OUT/t$t/r$r"
    mkdir -p "$d"
    /usr/bin/time -f '%e' -o "$d/wall.txt" env OMP_NUM_THREADS="$t" "$OUT/pivot_opt" "$IN" > "$d/stdout.txt" 2>&1
    cp result.txt "$d/result.txt"
    w=$(tail -1 "$d/wall.txt")
    s=$(grep -o 'Using time : [0-9.]*' "$d/stdout.txt" | tail -1 | awk '{print $4}')
    if diff -q result.txt "$REF" >/dev/null; then same=SAME; else same=DIFF; fi
    echo "threads=$t r$r wall=$w self=$s $same" | tee -a "$OUT/timing.txt"
  done
done

echo "=== verify ===" | tee "$OUT/verify.txt"
for f in "$OUT"/t*/r*/result.txt "$OUT/base_result.txt"; do
  if diff -q "$f" "$REF" >/dev/null; then echo "SAME $f" >> "$OUT/verify.txt"
  else echo "DIFF $f" >> "$OUT/verify.txt"; fi
done
cat "$OUT/verify.txt"
echo "artifacts in $OUT/"
