#!/bin/bash
# Shared benchmark runners, sourced by tool/run_all.sh and
# tool/rerun_memory.sh (expects to run from packages/cocoon_bench).
#
# Every measurement is one FRESH `dart run` process (so memory numbers never
# leak between runs), RUNS times; the median lands in the RESULTS.md tables.
# Raw JSON per (size, engine, op) goes to results/<size>_<engine>_<op>.json.

export PATH=/root/development/flutter/bin:/root/.pub-cache/bin:$PATH
# Pinned, not inherited: every measurement must use the same database
# location, and the agent runtime's TMPDIR must never leak in here.
export TMPDIR=/tmp/cocoon_bench_run
mkdir -p "$TMPDIR" results
RUNS=${RUNS:-3}
# Any single run may take at most 10 minutes; over that, record a timeout.
TIMEBOX=${TIMEBOX:-600}

# One fresh process: prints the result JSON on stdout's last line.
# Echoes the JSON, or {"timeout":true,...} when the run exceeded TIMEBOX.
# Extra bench flags (e.g. "--durability normal") come after the op.
run_one() { # engine size op [extra flags...]
  local engine=$1 size=$2 op=$3 extra="${4:-}" out code
  out=$(timeout "$TIMEBOX" dart run bin/bench.dart \
    --engine "$engine" --size "$size" --op "$op" $extra 2>/dev/null)
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

# Collects RUNS fresh-process results into
# results/<size>_<engine>_<op>[_<suffix>].json.
collect() { # engine size op [suffix] [extra flags...]
  local engine=$1 size=$2 op=$3 suffix=${4:-} extra="${5:-}" runs="[" i
  for i in $(seq 1 $RUNS); do
    local one
    one=$(run_one "$engine" "$size" "$op" "$extra") || return 1
    runs="$runs$one"
    [ "$i" -lt "$RUNS" ] && runs="$runs,"
  done
  local file="results/${size}_${engine}_${op}${suffix:+_$suffix}.json"
  printf '{"engine":"%s","size":%s,"op":"%s","runs":%s]}\n' \
    "$engine" "$size" "$op" "$runs" > "$file"
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

# Imports (3 fresh runs, rebuilding the import JSON) only when the engine's
# database for this size is missing — the read ops measure against the
# imported database, not the harness's dataset.
ensure_db() { # engine size
  local engine=$1 size=$2 file
  case "$engine" in
    cocoon) file="$TMPDIR/cocoon_bench_${engine}_$size/cocoon.db" ;;
    sembast) file="$TMPDIR/cocoon_bench_${engine}_$size/sembast.db" ;;
    *) return 1 ;;
  esac
  if [ ! -f "$file" ]; then
    echo "db missing: $file — importing first" >&2
    collect "$engine" "$size" import || return 1
  fi
}
