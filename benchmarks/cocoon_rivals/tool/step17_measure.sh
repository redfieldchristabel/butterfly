#!/bin/bash
# Step 17 aggregates: measures cocoon-normal's monthly / yearreport / count
# ops at 1M, RUNS fresh processes per op (the harness's usual 3, median
# taken by make_results.py), writing raw JSON into results/step17/.
# usage: tool/step17_measure.sh before|after
set -u
cd "$(dirname "$0")/.."
export PATH=/root/development/flutter/bin:/root/.pub-cache/bin:$PATH
export TMPDIR=/tmp/cocoon_rivals_run
mkdir -p "$TMPDIR" results/step17

PHASE=$1
SIZE=1000000
ENGINE=cocoon-normal
RUNS=${RUNS:-3}

for op in monthly yearreport count; do
  runs="["
  for i in $(seq 1 "$RUNS"); do
    echo "[$PHASE] $ENGINE $SIZE $op run $i/$RUNS" >&2
    out=$(timeout 600 dart run bin/bench.dart \
      --engine "$ENGINE" --size "$SIZE" --op "$op" 2>/dev/null)
    code=$?
    if [ $code -ne 0 ]; then
      echo "{\"failed\":$code}" >&2
      exit 1
    fi
    one=$(echo "$out" | tail -1)
    runs="$runs$one"
    [ "$i" -lt "$RUNS" ] && runs="$runs,"
  done
  runs="$runs]"
  file="results/step17/${PHASE}_${SIZE}_${ENGINE}_${op}.json"
  printf '{"engine":"%s","size":%s,"op":"%s","phase":"%s","runs":%s}\n' \
    "$ENGINE" "$SIZE" "$op" "$PHASE" "$runs" > "$file"
  echo "wrote $file" >&2
done

# The at-scale correctness dump: cocoon's verify output after this phase,
# compared against drift's stored v2 dump.
out=$(timeout 900 dart run bin/bench.dart \
  --engine "$ENGINE" --size "$SIZE" --op verify 2>/dev/null)
one=$(echo "$out" | tail -1)
printf '{"engine":"%s","size":%s,"op":"verify","phase":"%s","runs":[%s]}\n' \
  "$ENGINE" "$SIZE" "$PHASE" "$one" > "results/step17/${PHASE}_${SIZE}_${ENGINE}_verify.json"
echo "wrote results/step17/${PHASE}_${SIZE}_${ENGINE}_verify.json" >&2
tool/check_verify.py results/1000000_drift_verify.json \
  "results/step17/${PHASE}_${SIZE}_${ENGINE}_verify.json" || exit 1
echo "[$PHASE] verify matches drift" >&2
