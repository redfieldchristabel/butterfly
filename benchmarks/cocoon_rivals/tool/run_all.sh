#!/bin/bash
# Reproduces every number in RESULTS.md: the rivals matrix, up to 1M rows.
#
# For each size and engine, every operation runs in a FRESH `dart run`
# process (so memory numbers never leak between runs), RUNS times; the median
# lands in the RESULTS.md tables. Raw JSON per (size, engine, op) goes to
# results/<size>_<engine>_<op>.json, the harness-only memory floor to
# results/baseline.json, machine info to results/env.json.
#
# Resumable: a (size, engine, op) whose results file already exists is
# skipped — delete that file to re-measure it. `verify` runs once per
# engine and size (a correctness dump, no timing; check_verify compares it
# against cocoon's).
#
# usage: tool/run_all.sh [sizes...]   (default: 10000 100000 300000 1000000)
set -u
cd "$(dirname "$0")/.."

source tool/lib.sh

SIZES=("$@")
[ ${#SIZES[@]} -eq 0 ] && SIZES=(10000 100000 300000 1000000)

# The ops measured per engine, in order. `import` builds the database the
# read ops run against; `verify` (once, untimed output dump) checks the read
# contracts at scale BEFORE any timing counts; `rww` adds writer txns, so it
# runs after the pure reads; `restore` rebuilds its own directory.
OPS="verify open rss latest50 monthly gets write range yearreport statussearch bigspend amountrange pendingmonth deeppage count rww restore"

echo "== machine ==" >&2
dart run bin/bench.dart --engine cocoon --size 1 --op env | tail -1 \
  > results/env.json
cat results/env.json >&2

[ -f results/baseline.json ] || collect_baseline

for size in "${SIZES[@]}"; do
  for engine in $ENGINES; do
    echo "== $engine @ $size ==" >&2
    if [ ! -f "results/${size}_${engine}_import.json" ]; then
      # The import wipes and rebuilds on every run.
      collect "$engine" "$size" import
    else
      echo "skip results/${size}_${engine}_import.json (present)" >&2
    fi
    ensure_db "$engine" "$size" || continue
    for op in $OPS; do
      if [ -f "results/${size}_${engine}_${op}.json" ]; then
        echo "skip results/${size}_${engine}_${op}.json (present)" >&2
        continue
      fi
      if [ "$op" = verify ]; then
        collect_verify "$engine" "$size" || continue
      else
        collect "$engine" "$size" "$op" || continue
      fi
    done
  done
done

# The at-scale correctness check: every engine's verify dump against
# cocoon's, per size. Fails loudly on the first mismatch.
echo "== correctness (verify vs cocoon) ==" >&2
fail=0
for size in "${SIZES[@]}"; do
  for engine in $ENGINES; do
    [ "$engine" = cocoon ] && continue
    f="results/${size}_${engine}_verify.json"
    c="results/${size}_cocoon_verify.json"
    [ -f "$f" ] && [ -f "$c" ] || continue
    if ! tool/check_verify.py "$c" "$f"; then
      echo "VERIFY MISMATCH: $engine @ $size" >&2
      fail=1
    fi
  done
done
[ $fail -eq 0 ] && echo "verify: all engines match cocoon" >&2

echo "all results in $(pwd)/results/" >&2
