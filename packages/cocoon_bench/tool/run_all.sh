#!/bin/bash
# Reproduces every number in RESULTS.md.
#
# For each size and engine, every operation runs in a FRESH `dart run`
# process (so memory numbers never leak between runs), RUNS times; the
# median lands in the RESULTS.md tables. Raw JSON per (size, engine, op)
# goes to results/<size>_<engine>_<op>.json, the harness-only memory floor
# to results/baseline.json, machine info to results/env.json.
#
# usage: tool/run_all.sh [sizes...]   (default: 10000 100000 300000)
set -u
cd "$(dirname "$0")/.."

source tool/lib.sh

SIZES=("$@")
[ ${#SIZES[@]} -eq 0 ] && SIZES=(10000 100000 300000)

echo "== machine ==" >&2
dart run bin/bench.dart --engine cocoon --size 1 --op env | tail -1 \
  > results/env.json
cat results/env.json >&2

collect_baseline

for size in "${SIZES[@]}"; do
  for engine in cocoon sembast; do
    echo "== $engine @ $size ==" >&2
    # The import builds the database the read ops below run against; it
    # wipes and rebuilds on every run.
    collect "$engine" "$size" import
    collect "$engine" "$size" open
    collect "$engine" "$size" rss
    collect "$engine" "$size" latest50
    collect "$engine" "$size" monthly
    collect "$engine" "$size" gets
    collect "$engine" "$size" write
    if [ "$engine" = cocoon ]; then
      # The tuning knobs, one at a time, against the defaults above.
      collect "$engine" "$size" write normal "--durability normal"
      collect "$engine" "$size" write nokeep "--keep-changes false"
      collect "$engine" "$size" gets2 cache2000 "--cache-size 2000"
      collect "$engine" "$size" gets2 cache20000 "--cache-size 20000"
    fi
  done
done

echo "all results in $(pwd)/results/" >&2
