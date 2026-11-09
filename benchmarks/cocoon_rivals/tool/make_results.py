#!/usr/bin/env python3
"""Builds RESULTS.md from the raw JSON in results/.

usage: make_results.py > RESULTS.md   (run from benchmarks/cocoon_rivals)

Every measurement cell is the median of the fresh-process runs recorded in
results/<size>_<engine>_<op>.json. Memory numbers are the run's own RSS minus
the median bare-harness baseline. Missing files render as '—', timeouts as
'timeout', other failures as 'failed'.
"""
import glob
import json
import os
import statistics
import sys

ENGINES = [
    "cocoon",
    "cocoon-normal",
    "drift",
    "isar",
    "objectbox",
    "hive",
    "sembast",
]
SIZES = [10000, 100000, 300000, 1000000]

MB = 1024 * 1024


def load(path):
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return json.load(f)


def med(runs, key):
    """Median of one metric over the recorded runs, None when absent."""
    values = [r[key] for r in runs if key in r and r[key] is not None]
    if not values:
        return None
    return statistics.median(values)


def cell(runs, key, scale=1.0, digits=1, fmt="f", minus=None):
    """One table cell: median scaled, or the timeout/failed marker.

    `runs` is the parsed results file ({"engine", "size", "op", "runs":
    [...]}) or the runs list itself. `minus` subtracts a baseline median
    first (memory rows: the bare-harness floor), so the cell shows the
    engine's own share.
    """
    if runs is None:
        return "—"
    if isinstance(runs, dict):
        runs = runs.get("runs") or []
    if any("timeout" in r for r in runs):
        return "timeout"
    if any("failed" in r for r in runs):
        return "failed"
    value = med(runs, key)
    if value is None:
        return "—"
    if minus is not None:
        value -= minus
    if fmt == "f":
        return f"{value / scale:.{digits}f}"
    return f"{int(value)}"


def med_ms(runs, key="elapsedMs"):
    return med(runs, key)


def main():
    env = load("results/env.json") or {}
    baseline = load("results/baseline.json")
    base_rss = (med(baseline["runs"], "rssBytes") if baseline else 0) or 0
    base_peak = (med(baseline["runs"], "peakRssBytes") if baseline else 0) or 0

    out = []
    w = out.append
    w("# Cocoon vs the real local-database rivals")
    w("")
    w(
        "An honest benchmark of Cocoon against the engines a big "
        "on-device app would actually pick — drift (plain SQLite, the "
        "speed limit), Isar, ObjectBox, Hive CE and sembast — on "
        "finance-shaped data at up to 1,000,000 transactions."
    )
    w("")
    w(
        "Workloads are the ones a big finance app runs: bulk import, cold "
        "open, one account's latest-50, monthly totals, random gets, single "
        "writes, plus the all-accounts shapes (month range, year report, "
        "status search), read-while-write, and a 300k-restore from an NDJSON "
        "backup. Every run is a fresh process; every number is the median of "
        "three runs; every memory number is the run's own share — the RSS "
        "rows minus the bare harness's RSS, the peak row minus the bare "
        "harness's peak. A cell says `timeout` when the 10-minute box cut "
        "the run off. Correctness first: a 500-txn smoke test asserts every "
        "engine returns identical, contract-ordered results for every "
        "workload (`dart test` here), and at every measured size a `verify` "
        "dump is diffed against Cocoon's before any timing counts."
    )
    w("")
    w("## Machine")
    w("")
    w(f"- Dart {env.get('dart', '?')}, SQLite {env.get('sqlite', '?')}")
    w(
        f"- {env.get('cpu', '?')}, {env.get('cores', '?')} cores, "
        f"{env.get('ramTotalMb', '?')} MB RAM"
    )
    w(f"- Harness floor: {base_rss / MB:.0f} MB RSS, peak {base_peak / MB:.0f} MB")
    w("")

    for size in SIZES:
        w(f"## {size:,} transactions")
        w("")
        rows = [
            (
                "Import (s)",
                lambda e: cell(
                    load(f"results/{size}_{e}_import.json"), "elapsedMs", 1000
                ),
            ),
            (
                "File size (MB)",
                lambda e: cell(
                    load(f"results/{size}_{e}_import.json"), "fileBytes", MB
                ),
            ),
            (
                "Cold open (ms)",
                lambda e: cell(
                    load(f"results/{size}_{e}_open.json"), "openMs", 1, 0
                ),
            ),
            (
                "RSS after open, − floor (MB)",
                lambda e: cell(
                    load(f"results/{size}_{e}_rss.json"),
                    "rssAfterOpenBytes",
                    MB,
                    minus=base_rss,
                ),
            ),
            (
                "RSS after reads, − floor (MB)",
                lambda e: cell(
                    load(f"results/{size}_{e}_rss.json"),
                    "rssAfterReadsBytes",
                    MB,
                    minus=base_rss,
                ),
            ),
            (
                "Peak RSS, − floor peak (MB)",
                lambda e: cell(
                    load(f"results/{size}_{e}_rss.json"),
                    "peakRssBytes",
                    MB,
                    minus=base_peak,
                ),
            ),
            (
                "Latest-50 p50 (ms)",
                lambda e: cell(
                    load(f"results/{size}_{e}_latest50.json"), "p50Us", 1000
                ),
            ),
            (
                "Latest-50 p95 (ms)",
                lambda e: cell(
                    load(f"results/{size}_{e}_latest50.json"), "p95Us", 1000
                ),
            ),
            (
                "Monthly totals (ms)",
                lambda e: cell(
                    load(f"results/{size}_{e}_monthly.json"), "elapsedMs", 1, 0
                ),
            ),
            (
                "1,000 random gets (ms)",
                lambda e: cell(
                    load(f"results/{size}_{e}_gets.json"), "elapsedMs", 1, 0
                ),
            ),
            (
                "Single write p50 (µs)",
                lambda e: cell(
                    load(f"results/{size}_{e}_write.json"), "p50Us", 1, 0
                ),
            ),
            (
                "Single write p95 (µs)",
                lambda e: cell(
                    load(f"results/{size}_{e}_write.json"), "p95Us", 1, 0
                ),
            ),
            (
                "Month range, all accounts (ms)",
                lambda e: cell(
                    load(f"results/{size}_{e}_range.json"), "elapsedMs", 1, 0
                ),
            ),
            (
                "Year report, all accounts (ms)",
                lambda e: cell(
                    load(f"results/{size}_{e}_yearreport.json"),
                    "elapsedMs",
                    1,
                    0,
                ),
            ),
            (
                "Status search p50 (ms)",
                lambda e: cell(
                    load(f"results/{size}_{e}_statussearch.json"),
                    "p50Us",
                    1000,
                ),
            ),
            (
                "Status search p95 (ms)",
                lambda e: cell(
                    load(f"results/{size}_{e}_statussearch.json"),
                    "p95Us",
                    1000,
                ),
            ),
            (
                "Read-while-write p95 (ms)",
                lambda e: cell(load(f"results/{size}_{e}_rww.json"), "p95Us", 1000),
            ),
            (
                "Restore 300k from NDJSON (s)",
                lambda e: cell(
                    load(f"results/{size}_{e}_restore.json"), "elapsedMs", 1000
                ),
            ),
        ]
        header = "| Workload | " + " | ".join(ENGINES) + " |"
        sep = "|---|" + "|".join(["---"] * len(ENGINES)) + "|"
        w(header)
        w(sep)
        for label, get in rows:
            cells = [get(e) for e in ENGINES]
            w(f"| {label} | " + " | ".join(cells) + " |")
        w("")

    w("## Verdicts")
    w("")
    w("(Written by hand from the tables above — see the repo history.)")
    w("")
    sys.stdout.write("\n".join(out))


if __name__ == "__main__":
    main()
