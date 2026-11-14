#!/usr/bin/env bash
# The isolate-mode benchmark: seeds each size once, then measures every
# operation in all three isolate modes (one process per run, so peak RSS
# never leaks between runs). Every raw JSON result line lands on stdout
# (piped through the formatter, which passes seeds and errors through
# verbatim), followed by the assembled markdown table.
#
# usage: bash tool/run_isolate_bench.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/root/development/flutter/bin:/root/.pub-cache/bin:$PATH"
export TMPDIR="${TMPDIR:-/tmp}"

RAW=$(mktemp)
trap 'rm -f "$RAW"' EXIT

echo "== seeding =="
for size in 1000 10000 100000; do
  dart run bin/isolate_bench.dart --role seed --size "$size" 2>/dev/null | tail -1 | tee -a "$RAW"
done

echo "== runs =="
for mode in caller background auto; do
  for spec in 'page 10000' 'group 100000' 'import 100000' 'latency 1000' 'writes 1000' 'mixed 10000'; do
    set -- $spec
    echo "-- $mode $1 $2"
    dart run bin/isolate_bench.dart --mode "$mode" --op "$1" --size "$2" 2>/dev/null | tail -1 | tee -a "$RAW"
  done
done

echo "== table =="
printf '| op | mode | wall ms | longest stall ms | total stall ms | stalls >8ms | peak RSS MB |\n'
printf '|---|---|---|---|---|---|---|\n'
# Filter AFTER the formatter: it renders the JSON seed lines as "seed ..."
# text, so they must be dropped from its output, not its input.
python3 tool/format_isolate_bench.py < "$RAW" | grep -v '^seed'
