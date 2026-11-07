#!/bin/bash
# Reproduces every number in ../RESULTS.md.
#
# For each size and engine, every operation runs in a FRESH `dart run`
# process (so memory numbers never leak between runs), RUNS times; the
# median lands in the RESULTS.md tables. Raw JSON per (size, engine, op)
# goes to results/<size>_<engine>_<op>.json, machine info to results/env.json.
#
# usage: tool/run_all.sh [sizes...]   (default: 10000 100000 300000)
set -u
cd "$(dirname "$0")/.."

export PATH=/root/development/flutter/bin:/root/.pub-cache/bin:$PATH
export TMPDIR=/tmp/cocoon_bench_run
mkdir -p "$TMPDIR" results

SIZES=("$@")
[ ${#SIZES[@]} -eq 0 ] && SIZES=(10000 100000 300000)
RUNS=3
# Any single run may take at most 10 minutes; over that, record a timeout.
TIMEBOX=600

# One fresh process: prints the result JSON on stdout's last line.
# Echoes the JSON, or {"timeout":true,...} when the run exceeded TIMEBOX.
run_one() { # engine size op
  local engine=$1 size=$2 op=$3 out code
  out=$(timeout "$TIMEBOX" dart run bin/bench.dart \
    --engine "$engine" --size "$size" --op "$op" 2>/dev/null)
  code=$?
  if [ $code -eq 124 ]; then
    echo "{\"engine\":\"$engine\",\"size\":$size,\"op\":\"$op\",\"timeout\":true}"
  elif [ $code -ne 0 ]; then
    echo "{\"engine\":\"$engine\",\"size\":$size,\"op\":\"$op\",\"failed\":$code}" >&2
    return 1
  else
    echo "$out" | tail -1
  fi
}

# Collects RUNS fresh-process results into results/<size>_<engine>_<op>.json.
collect() { # engine size op
  local engine=$1 size=$2 op=$3 runs="[" i
  for i in $(seq 1 $RUNS); do
    local one
    one=$(run_one "$engine" "$size" "$op") || return 1
    runs="$runs$one"
    [ "$i" -lt "$RUNS" ] && runs="$runs,"
  done
  local file="results/${size}_${engine}_${op}.json"
  printf '{"engine":"%s","size":%s,"op":"%s","runs":%s]}\n' \
    "$engine" "$size" "$op" "$runs" > "$file"
  echo "wrote $file" >&2
}

echo "== machine ==" >&2
dart run bin/bench.dart --engine cocoon --size 1 --op env | tail -1 \
  > results/env.json
cat results/env.json >&2

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
  done
done

echo "all results in $(pwd)/results/" >&2
