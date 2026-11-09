#!/bin/bash
# Shared benchmark runners for the rivals harness, sourced by tool/run_all.sh.
# Every measurement is one FRESH `dart run` process (so memory numbers never
# leak between runs), RUNS times; the median lands in the RESULTS.md tables.
# Raw JSON per (size, engine, op) goes to results/<size>_<engine>_<op>.json.

export PATH=/root/development/flutter/bin:/root/.pub-cache/bin:$PATH
# Pinned, not inherited: every measurement must use the same database
# location, and the agent runtime's TMPDIR must never leak in here.
export TMPDIR=/tmp/cocoon_rivals_run
mkdir -p "$TMPDIR" results
RUNS=${RUNS:-3}
# Any single run may take at most 10 minutes; over that, record a timeout.
TIMEBOX=${TIMEBOX:-600}

ENGINES=${ENGINES:-"cocoon cocoon-normal drift isar objectbox hive sembast"}

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

# The correctness dump at this size, once (no timing): every read shape's
# full output, diffed against cocoon's by check_verify.
collect_verify() { # engine size
  local engine=$1 size=$2 one file="results/${size}_${engine}_verify.json"
  one=$(run_one "$engine" "$size" verify) || return 1
  printf '{"engine":"%s","size":%s,"op":"verify","runs":[%s]}\n' \
    "$engine" "$size" "$one" > "$file"
  echo "wrote $file" >&2
}

# The harness floor: RSS of a bare `dart run` of bin/bench.dart with nothing
# opened. Engine memory minus this is the engine's own share.
collect_baseline() {
  local runs="[" i one
  for i in $(seq 1 $RUNS); do
    one=$(timeout "$TIMEBOX" dart run bin/bench.dart --op baseline 2>/dev/null |
      tail -1) || return 1
    runs="$runs$one"
    [ "$i" -lt "$RUNS" ] && runs="$runs,"
  done
  printf '{"op":"baseline","runs":%s]}\n' "$runs" > results/baseline.json
  echo "wrote results/baseline.json" >&2
}

# Imports (rebuilding the import JSON) only when the engine's database for
# this size is missing — the read ops measure against the imported database.
ensure_db() { # engine size
  local engine=$1 size=$2 dir="$TMPDIR/cocoon_rivals_${engine}_$size"
  local missing=1
  case "$engine" in
    cocoon|cocoon-normal) [ -f "$dir/cocoon.db" ] && missing=0 ;;
    sembast) [ -f "$dir/sembast.db" ] && missing=0 ;;
    drift) [ -f "$dir/drift.db" ] && missing=0 ;;
    isar) [ -d "$dir/isar" ] && missing=0 ;;
    objectbox) [ -d "$dir/objectbox" ] && missing=0 ;;
    hive) ls "$dir"/*.hive >/dev/null 2>&1 && missing=0 ;;
  esac
  if [ "$missing" -eq 1 ]; then
    echo "db missing: $dir — importing first" >&2
    collect "$engine" "$size" import || return 1
  fi
}
