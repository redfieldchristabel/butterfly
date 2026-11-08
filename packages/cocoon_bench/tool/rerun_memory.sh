#!/bin/bash
# Step-8 re-measurements: the harness-only memory floor (results/baseline.json),
# the dataset-free open + rss for both engines at every size, and the two
# knobs the first run skipped — single-write latency with Durability.normal
# and with keepChanges:false at 100k, and gets by id with cacheSize 2000 vs
# 20000 at 100k/300k (cold + warm in one process, RSS after each). Databases
# are reused from an earlier import; only missing ones are rebuilt.
set -u
cd "$(dirname "$0")/.."

source tool/lib.sh

collect_baseline || exit 1

for size in 10000 100000 300000; do
  for engine in cocoon sembast; do
    echo "== $engine @ $size ==" >&2
    ensure_db "$engine" "$size" || exit 1
    collect "$engine" "$size" open || exit 1
    collect "$engine" "$size" rss || exit 1
  done
done

echo "== knobs ==" >&2
collect cocoon 100000 write normal "--durability normal" || exit 1
collect cocoon 100000 write nokeep "--keep-changes false" || exit 1
for size in 100000 300000; do
  collect cocoon "$size" gets2 cache2000 "--cache-size 2000" || exit 1
  collect cocoon "$size" gets2 cache20000 "--cache-size 20000" || exit 1
done

echo "step-8 reruns done: $(pwd)/results/" >&2
