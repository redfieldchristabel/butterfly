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
        "status search), the query-specialist shapes (bigspend, amount "
        "range, pending month, deep page, counts), read-while-write, and a "
        "300k-restore from an NDJSON backup. Every run is a fresh process; "
        "every number is the median of three runs; every memory number is "
        "the run's own share — the RSS rows minus the bare harness's RSS, "
        "the peak rows minus the bare harness's peak. A cell says `timeout` "
        "when the 10-minute box cut the run off. Correctness first: a "
        "500-txn smoke test asserts every engine returns identical, "
        "contract-ordered results for every workload (`dart test` here), "
        "and at every measured size a `verify` dump is diffed against "
        "Cocoon's before any timing counts."
    )
    w("")
    w("### The workloads")
    w("")
    w(
        "- **bigspend** — the 50 largest debits across all accounts: "
        "`amountMinor ASC` (most negative first), ties by string id `ASC`, "
        "limit 50; 50 runs, p50/p95. No amount filter: with the dataset's "
        "distribution the 50 smallest amounts are always debits, and every "
        "engine must return the same ids."
    )
    w(
        "- **amountrange** — every txn with `amountMinor` in the fixed band "
        "[150000, 166500) minor units, chosen once from the dataset's "
        "distribution so it returns ~1% of the rows (measured 0.96% at 10k, "
        "1.00% at 100k, 1.00% at 300k txns; the amounts are ±(100..990099), "
        "40% negative, and the band sits on the credit side): all accounts, "
        "`amountMinor ASC`, ties by id `ASC`, paged by 100. Reports "
        "elapsed ms, pages, count."
    )
    w(
        "- **pendingmonth** — the compound filter: `status == pending` AND "
        "`bookedOn` in 202406 (rangeMonthKey), all accounts, `bookedOn ASC`, "
        "ties by id `ASC`, paged by 100 — served by the `(status, bookedOn)` "
        "index where one exists. Reports elapsed ms, pages, count."
    )
    w(
        "- **deeppage** — one account's history newest-first, 20 pages of "
        "50 by the engine's own paging idiom (keyset cursor for Cocoon; "
        "offset paging for drift, Isar, ObjectBox and sembast — their "
        "documented idiom; the in-RAM list slice for Hive). Run over 10 "
        "accounts; reports per-page p50/p95 and the page-20 duration (its "
        "median over the accounts that walked that deep) — whether paging "
        "stays flat deep into history."
    )
    w(
        "- **count** — (1) `pending` txns across all accounts, (2) one "
        "account's (a05) txns in the 2024 report year: Cocoon "
        "`query.count()`, drift `SELECT count(*)`, isar `.count()`, "
        "objectbox `query.count()`, hive/sembast a scan; 20 runs each, "
        "p50/p95 per shape."
    )
    w("")
    w("### The cost metrics")
    w("")
    w(
        "Every op also reports `peakRssBytes` (the process high-water mark), "
        "`cpuMs` (the process's user+sys CPU over the op's measured section "
        "— the `/proc/self/stat` utime+stime delta at `getconf CLK_TCK` "
        "ticks/s) and `diskWriteBytes` (the `/proc/self/io` `write_bytes` "
        "delta over the same section, so native and isolate threads count). "
        "`import` adds `writeAmplification` = diskWriteBytes / final file "
        "size. The cpu/io sections are the same sections the wall-time "
        "metrics cover (open/seed/sample setup stays outside), except that "
        "import and restore bracket their engine's whole call (the engine's "
        "untimed accounts / fresh open live inside). `cpuMs` can "
        "legitimately be 0 for very fast ops at the kernel's tick "
        "granularity. `diskWriteBytes` needs kernel io accounting "
        "(`/proc/self/io`); kernels built without `CONFIG_TASK_IO_ACCOUNTING`"
        " — this WSL2 box's microsoft-standard kernel among them — have no "
        "per-process disk numbers, the key is omitted and the disk rows "
        "below render as '—'; on mainline/Android kernels they fill in. "
        "The tables use the cost metrics for import (CPU, disk written, "
        "write amplification) and for the two peak-RSS rows (import, "
        "restore)."
    )
    w("")
    w(
        "Raw SQLite itself is mapped separately in [CEILING.md](CEILING.md):"
        " what the fastest possible load of Cocoon's real table costs and "
        "what each lever (deferred indexes, one transaction, change-log "
        "granularity, synchronous, rowid keys) buys at 1M."
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
                "Bulk import (s)",
                lambda e: cell(
                    load(f"results/{size}_{e}_bulkimport.json"),
                    "elapsedMs",
                    1000,
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
                "Bigspend p50 (ms)",
                lambda e: cell(
                    load(f"results/{size}_{e}_bigspend.json"), "p50Us", 1000
                ),
            ),
            (
                "Bigspend p95 (ms)",
                lambda e: cell(
                    load(f"results/{size}_{e}_bigspend.json"), "p95Us", 1000
                ),
            ),
            (
                "Amount range, all accounts (ms)",
                lambda e: cell(
                    load(f"results/{size}_{e}_amountrange.json"),
                    "elapsedMs",
                    1,
                    0,
                ),
            ),
            (
                "Pending month, all accounts (ms)",
                lambda e: cell(
                    load(f"results/{size}_{e}_pendingmonth.json"),
                    "elapsedMs",
                    1,
                    0,
                ),
            ),
            (
                "Deep page p50 (ms)",
                lambda e: cell(
                    load(f"results/{size}_{e}_deeppage.json"), "p50Us", 1000
                ),
            ),
            (
                "Deep page p95 (ms)",
                lambda e: cell(
                    load(f"results/{size}_{e}_deeppage.json"), "p95Us", 1000
                ),
            ),
            (
                "Deep page 20 (ms)",
                lambda e: cell(
                    load(f"results/{size}_{e}_deeppage.json"), "page20Us", 1000
                ),
            ),
            (
                "Count pending p50 (ms)",
                lambda e: cell(
                    load(f"results/{size}_{e}_count.json"),
                    "pendingP50Us",
                    1000,
                ),
            ),
            (
                "Count year p50 (ms)",
                lambda e: cell(
                    load(f"results/{size}_{e}_count.json"), "yearP50Us", 1000
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
            (
                "Import peak RSS, − floor peak (MB)",
                lambda e: cell(
                    load(f"results/{size}_{e}_import.json"),
                    "peakRssBytes",
                    MB,
                    minus=base_peak,
                ),
            ),
            (
                "Import CPU (s)",
                lambda e: cell(
                    load(f"results/{size}_{e}_import.json"), "cpuMs", 1000
                ),
            ),
            (
                "Import disk written (MB)",
                lambda e: cell(
                    load(f"results/{size}_{e}_import.json"),
                    "diskWriteBytes",
                    MB,
                ),
            ),
            (
                "Import write amplification (x)",
                lambda e: cell(
                    load(f"results/{size}_{e}_import.json"),
                    "writeAmplification",
                    1,
                    2,
                ),
            ),
            (
                "Restore peak RSS, − floor peak (MB)",
                lambda e: cell(
                    load(f"results/{size}_{e}_restore.json"),
                    "peakRssBytes",
                    MB,
                    minus=base_peak,
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
