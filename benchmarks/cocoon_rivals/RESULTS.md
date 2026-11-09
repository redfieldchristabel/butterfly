# Cocoon vs the real local-database rivals

An honest benchmark of Cocoon against the engines a big on-device app would actually pick — drift (plain SQLite, the speed limit), Isar, ObjectBox, Hive CE and sembast — on finance-shaped data at up to 1,000,000 transactions.

Workloads are the ones a big finance app runs: bulk import, cold open, one account's latest-50, monthly totals, random gets, single writes, plus the all-accounts shapes (month range, year report, status search), read-while-write, and a 300k-restore from an NDJSON backup. Every run is a fresh process; every number is the median of three runs; every memory number is the run's own share — the RSS rows minus the bare harness's RSS, the peak row minus the bare harness's peak. A cell says `timeout` when the 10-minute box cut the run off. Correctness first: a 500-txn smoke test asserts every engine returns identical, contract-ordered results for every workload (`dart test` here), and at every measured size a `verify` dump is diffed against Cocoon's before any timing counts.

## Machine

- Dart 3.13.7, SQLite 3.54.1
- Intel(R) Core(TM) Ultra 5 325, 8 cores, 27405 MB RAM
- Harness floor: 431 MB RSS, peak 451 MB

## 10,000 transactions

| Workload | cocoon | cocoon-normal | drift | isar | objectbox | hive | sembast |
|---|---|---|---|---|---|---|---|
| Import (s) | 1.3 | 1.0 | 0.3 | 0.1 | 0.1 | 0.1 | 0.6 |
| File size (MB) | 8.6 | 8.6 | 2.2 | 5.0 | 6.8 | 3.0 | 2.7 |
| Cold open (ms) | 98 | 89 | 78 | 65 | 64 | 131 | 212 |
| RSS after open, − floor (MB) | 86.2 | 84.1 | 83.5 | 51.0 | 64.2 | 133.5 | -15.0 |
| RSS after reads, − floor (MB) | -9.8 | -8.3 | -25.9 | -50.8 | -44.5 | -18.3 | -17.3 |
| Peak RSS, − floor peak (MB) | 84.9 | 78.1 | 80.6 | 86.0 | 96.8 | 125.4 | 93.3 |
| Latest-50 p50 (ms) | 0.7 | 0.9 | 0.5 | 0.9 | 0.3 | 4.8 | 5.1 |
| Latest-50 p95 (ms) | 2.4 | 6.3 | 1.5 | 1.7 | 0.7 | 6.3 | 5.8 |
| Monthly totals (ms) | 17 | 19 | 20 | 21 | 9 | 5 | 49 |
| 1,000 random gets (ms) | 129 | 162 | 157 | 343 | 12 | 1 | 5 |
| Single write p50 (µs) | 1947 | 605 | 3198 | 1096 | 810 | 124 | 367 |
| Single write p95 (µs) | 3074 | 1176 | 5939 | 1573 | 1313 | 263 | 635 |
| Month range, all accounts (ms) | 30 | 33 | 16 | 22 | 12 | 10 | 53 |
| Year report, all accounts (ms) | 84 | 86 | 10 | 51 | 22 | 8 | 42 |
| Status search p50 (ms) | 1.3 | 1.3 | 0.8 | 1.1 | 0.5 | 5.4 | 6.9 |
| Status search p95 (ms) | 4.4 | 3.9 | 2.1 | 1.9 | 1.6 | 7.5 | 8.7 |
| Read-while-write p95 (ms) | 2.6 | 2.4 | 4.2 | 1.4 | 1.0 | 5.6 | 6.9 |
| Restore 300k from NDJSON (s) | 27.9 | 32.0 | 14.1 | 5.3 | 4.8 | 3.3 | 16.2 |

## 100,000 transactions

| Workload | cocoon | cocoon-normal | drift | isar | objectbox | hive | sembast |
|---|---|---|---|---|---|---|---|
| Import (s) | 7.9 | 7.8 | 2.7 | 1.0 | 1.0 | 0.7 | 4.7 |
| File size (MB) | 43.6 | 43.6 | 22.3 | 35.0 | 64.4 | 30.5 | 26.8 |
| Cold open (ms) | 95 | 95 | 86 | 72 | 71 | 577 | 890 |
| RSS after open, − floor (MB) | 87.0 | 57.9 | 66.0 | 55.8 | 56.7 | 206.0 | 156.6 |
| RSS after reads, − floor (MB) | -9.2 | -5.7 | -45.4 | -21.6 | 19.9 | 214.5 | 188.7 |
| Peak RSS, − floor peak (MB) | 79.1 | 98.5 | 81.6 | 111.9 | 153.6 | 194.4 | 169.6 |
| Latest-50 p50 (ms) | 0.8 | 0.8 | 0.5 | 5.1 | 4.1 | 71.5 | 78.1 |
| Latest-50 p95 (ms) | 2.8 | 2.6 | 1.5 | 6.5 | 4.9 | 80.2 | 94.3 |
| Monthly totals (ms) | 71 | 72 | 34 | 34 | 20 | 26 | 136 |
| 1,000 random gets (ms) | 139 | 136 | 108 | 982 | 10 | 3 | 55 |
| Single write p50 (µs) | 2083 | 578 | 3006 | 1175 | 839 | 117 | 358 |
| Single write p95 (µs) | 3122 | 1024 | 4171 | 1647 | 1606 | 253 | 650 |
| Month range, all accounts (ms) | 91 | 91 | 74 | 113 | 156 | 67 | 1398 |
| Year report, all accounts (ms) | 238 | 240 | 36 | 222 | 194 | 31 | 157 |
| Status search p50 (ms) | 1.5 | 1.6 | 0.8 | 6.9 | 6.2 | 67.1 | 115.9 |
| Status search p95 (ms) | 4.5 | 3.9 | 2.3 | 8.3 | 7.8 | 71.4 | 131.0 |
| Read-while-write p95 (ms) | 2.9 | 3.2 | 5.2 | 6.5 | 5.0 | 67.6 | 129.6 |
| Restore 300k from NDJSON (s) | 38.2 | 31.7 | 14.6 | 5.0 | 5.0 | 3.3 | 18.9 |

## 300,000 transactions

| Workload | cocoon | cocoon-normal | drift | isar | objectbox | hive | sembast |
|---|---|---|---|---|---|---|---|
| Import (s) | 32.2 | 28.7 | 15.1 | 4.6 | 3.6 | 2.3 | 13.7 |
| File size (MB) | 119.2 | 119.2 | 67.2 | 85.0 | 185.6 | 91.6 | 80.5 |
| Cold open (ms) | 102 | 104 | 76 | 83 | 78 | 1528 | 2587 |
| RSS after open, − floor (MB) | 77.0 | 66.8 | 85.0 | 56.1 | 66.3 | 672.2 | 551.7 |
| RSS after reads, − floor (MB) | -1.3 | -20.7 | -13.7 | 64.3 | 154.7 | 679.4 | 666.1 |
| Peak RSS, − floor peak (MB) | 88.2 | 88.1 | 89.5 | 165.5 | 267.4 | 659.2 | 646.1 |
| Latest-50 p50 (ms) | 0.8 | 0.8 | 0.5 | 14.7 | 12.4 | 205.1 | 225.2 |
| Latest-50 p95 (ms) | 3.1 | 2.7 | 1.2 | 17.7 | 13.5 | 208.7 | 229.8 |
| Monthly totals (ms) | 117 | 108 | 54 | 57 | 40 | 66 | 290 |
| 1,000 random gets (ms) | 123 | 103 | 77 | 2170 | 10 | 4 | 125 |
| Single write p50 (µs) | 2083 | 526 | 3373 | 1185 | 822 | 104 | 325 |
| Single write p95 (µs) | 3598 | 924 | 4321 | 1643 | 1950 | 220 | 583 |
| Month range, all accounts (ms) | 168 | 144 | 271 | 615 | 1157 | 188 | 9279 |
| Year report, all accounts (ms) | 499 | 455 | 101 | 552 | 516 | 74 | 342 |
| Status search p50 (ms) | 1.5 | 1.4 | 0.8 | 21.1 | 19.2 | 197.8 | 332.7 |
| Status search p95 (ms) | 4.4 | 4.8 | 2.3 | 24.2 | 20.8 | 203.9 | 341.4 |
| Read-while-write p95 (ms) | 3.0 | 2.5 | 4.7 | 18.3 | 15.6 | 210.4 | 304.1 |
| Restore 300k from NDJSON (s) | 35.8 | 29.8 | 13.8 | 4.8 | 5.0 | 3.1 | 14.2 |

## 1,000,000 transactions

| Workload | cocoon | cocoon-normal | drift | isar | objectbox | hive | sembast |
|---|---|---|---|---|---|---|---|
| Import (s) | 123.6 | 128.3 | 95.5 | 24.9 | 18.0 | 8.0 | 44.8 |
| File size (MB) | 375.4 | 375.4 | 224.2 | 265.0 | 609.0 | 305.4 | 268.3 |
| Cold open (ms) | 90 | 89 | 80 | 121 | 119 | 4657 | 7930 |
| RSS after open, − floor (MB) | 83.1 | 57.0 | 84.3 | 53.4 | 52.1 | 2232.8 | 1926.8 |
| RSS after reads, − floor (MB) | -4.3 | -0.8 | -28.4 | 262.0 | 538.8 | 2214.4 | 2242.3 |
| Peak RSS, − floor peak (MB) | 82.1 | 95.3 | 81.1 | 337.8 | 625.7 | 2459.8 | 2222.7 |
| Latest-50 p50 (ms) | 0.7 | 0.8 | 0.5 | 55.2 | 58.8 | 641.2 | 768.7 |
| Latest-50 p95 (ms) | 2.5 | 2.9 | 1.1 | 64.0 | 68.7 | 671.1 | 789.3 |
| Monthly totals (ms) | 181 | 176 | 99 | 122 | 128 | 169 | 767 |
| 1,000 random gets (ms) | 78 | 89 | 69 | 6590 | 14 | 4 | 309 |
| Single write p50 (µs) | 2978 | 402 | 2918 | 1135 | 768 | 112 | 297 |
| Single write p95 (µs) | 5676 | 701 | 3740 | 1617 | 1416 | 249 | 567 |
| Month range, all accounts (ms) | 320 | 314 | 2476 | 6374 | 13038 | 568 | 98982 |
| Year report, all accounts (ms) | 1377 | 1370 | 383 | 1916 | 1782 | 254 | 942 |
| Status search p50 (ms) | 1.4 | 1.4 | 0.8 | 84.4 | 65.6 | 607.7 | 1170.7 |
| Status search p95 (ms) | 4.4 | 4.4 | 2.6 | 95.0 | 70.7 | 619.0 | 1200.9 |
| Read-while-write p95 (ms) | 3.5 | 2.7 | 5.0 | 67.6 | 48.9 | 678.5 | 1000.3 |
| Restore 300k from NDJSON (s) | 33.0 | 28.7 | 13.9 | 4.8 | 4.8 | 3.0 | 14.0 |

## Verdicts

Written by hand from the tables above; every number quoted here is
computed from `results/*.json` — the same source `tool/make_results.py`
reads — so prose and tables cannot drift apart.

**A note on the data.** The first pass of this matrix ran on 2026-11-08
while an Android emulator and a Gradle build were active on this box
(`results/BUSY_WINDOWS.txt`: 02:00:00-02:49:55 UTC and 03:41:14-07:45:49
UTC). Before any table above was generated, every result file whose mtime
falls inside those windows was deleted and re-measured on the quiet box —
205 cells in total (a 206th cell was swept into `stale/` by mistake
although it was measured outside the windows, and was re-run with them;
the harness baseline was re-measured too). All re-runs went through the
resumable `tool/run_all.sh` with the emulator confirmed down first. The
superseded copies are parked in `results/stale/` (git-ignored) and
nothing in the tables above was measured inside a busy window.

### The one-paragraph version

**Cocoon wins the two things it exists for.** **Bounded RAM:** its own share
after the read workloads is at the floor (-4 MB) at 1M
transactions — flat from 10k, i.e. indistinguishable from a process that
opened nothing — while sembast holds every decoded record and sits
2,242 MB over the same floor. **Indexed reads at scale:**
one account's latest-50 stays at 0.74 ms p50 from 10k to 1M txns
(1,044x faster than sembast, 871x faster than Hive),
and the all-accounts month range runs in 320 ms at 1M —
7.7x faster than drift, whose idiomatic offset paging collapses with
size, and 309x faster than sembast. Against drift, the plain-SQL
speed limit, Cocoon's constant gap on the indexed reads (latest-50,
status search: 1.4-1.8x) is the price of the document layer. It loses,
and the losses are real: bulk import 123.6 s vs drift's
95.5 s (1.3x) and isar's 24.9 s (5x), file size
1.7x drift's, SQL aggregation 3.6x faster on the year report, gets by id
6x slower than ObjectBox and 20x slower than Hive, restore 2.4x slower than drift and
~11x slower than Hive, and single writes at the default durability equal
to drift's (2,978 µs vs 2,918 µs p50) — `Durability.normal`
(402 µs) is 7.3x faster than drift's default while staying
crash-safe.

### Import

Cocoon loses to every rival at every size, and this is the price of
everything else on this page: 1.26 → 7.94 → 32 → 124 s across the four
sizes. At 1M that is 123.6 s vs drift 95.5 s
(1.3x), sembast 44.8 s (2.8x),
isar 24.9 s (5.0x), hive
8.0 s and objectbox 18.0 s.
Every document is wire-encoded and written as one row plus one row per
index table plus change-log rows, in fsynced batches (`Durability.full`).
`cocoon-normal` does not help (128.3 s at 1M): batch
commits already amortize the fsync; the amplification is per row, not per
commit.

### Cold open

The SQLite-family engines all open flat: cocoon 98 → 95 → 102 → 90 ms,
drift 78 → 86 → 76 → 80 ms, isar 65 → 72 → 83 → 121 ms,
objectbox 64 → 71 → 78 → 119 ms. The log-parsers pay for their whole
history: hive 131 → 577 → 1,528 → 4,657 ms, sembast 212 → 890 → 2,587 → 7,930 ms —
at 1M sembast needs 7,930 ms before its first answer,
88.1x slower than Cocoon. (The `open` number is process start to
first query; the engine's own open is a few ms less.)

### Latest-50 for one account (p50)

Cocoon is flat over a 100x data range: 0.69 → 0.78 → 0.78 → 0.74 ms.
drift, the speed limit, is 0.48 → 0.54 → 0.54 → 0.49 ms — Cocoon's constant
1.5x gap is decode + object materialization, the cost of the
document layer. ObjectBox is the fastest engine at 10k (0.27 ms)
but grows with the data: 0.27 → 4.08 → 12 → 59 ms; isar grows to
55 ms at 1M (75.0x slower than Cocoon). Hive and
sembast have no index for this shape and scan their stores:
641 ms and 769 ms at 1M — 871x and
1,044x slower than Cocoon.

### Monthly totals, one account, one year

At 10k everything is fast and Hive wins (5.00 ms) because
its whole store is already in RAM. At 1M the order is drift
99 ms, objectbox 128 ms, isar
122 ms, hive 169 ms, cocoon
181 ms, sembast 767 ms.
Cocoon is 1.8x behind drift — drift sums the column in SQL,
Cocoon pages a year of an indexed range (500-doc pages) and sums in
Dart, because the Firestore-style API has no aggregate pushdown — and
4.2x ahead of sembast.

### 1,000 random gets by id

The in-RAM engines win, as designed: hive 1.00 → 3.00 → 4.00 → 4.00 ms
and objectbox 12 → 10 → 10 → 14 ms — their id is a hash or index
lookup in memory. sembast degrades with size (5.00 → 55 → 125 → 309 ms),
drift 157 → 108 → 77 → 69 ms, cocoon 129 → 139 → 123 → 78 ms — at 1M Cocoon is
1.1x behind drift (one SQLite SELECT + decode per id; the 2000-doc
LRU almost never hits on random ids) and 20x behind hive.
isar is the surprise: 343 → 982 → 2,170 → 6,590 ms — its id lookup degrades
badly with size (2,170 ms at 300k).

### Single writes (200 rewrites of sampled docs)

The fsync story. hive (124 → 117 → 104 → 112 µs), sembast
(367 → 358 → 325 → 297 µs) and objectbox (810 → 839 → 822 → 768 µs) append to a log
without fsyncing per record. drift (3,198 → 3,006 → 3,373 → 2,918 µs) and cocoon at
`Durability.full` (1,947 → 2,083 → 2,083 → 2,978 µs) both fsync every commit and are
statistically equal. `cocoon-normal` (`Durability.normal`, skip the fsync,
still crash-safe against application crashes) is 605 → 578 → 526 → 402 µs —
7.3x faster than drift's default at 1M. Cocoon-full's p95
(5,676 µs) is worse than drift's (3,740 µs): two index
B-trees and the change log grow with the file.

### Month range, all accounts (June 2024, paged)

Cocoon's clearest win at scale, and one over every rival: 30 → 91 → 168 → 320 ms.
drift is faster at 100k (74 ms) and then collapses
to 2,476 ms at 1M — its idiomatic paging is LIMIT/OFFSET,
which re-scans the index from the top for every page. ObjectBox
(1,157 ms at 300k, 13,038 ms at 1M) and isar
(615 ms at 300k, 6,374 ms at 1M) grow the same direction;
hive reaches 568 ms and sembast
98,982 ms (309x slower than Cocoon) at 1M. Keyset cursors,
not offsets, are why.

### Year report, all accounts (2024, 20 accounts x 12 months)

The honest loss to SQL: drift runs one GROUP BY/SUM and never leaves the
database: 10 → 36 → 101 → 383 ms. Hive aggregates its in-RAM copy:
8.00 → 31 → 74 → 254 ms. Cocoon pages 240 indexed range queries (20
accounts x 12 months) and sums in Dart: 84 → 238 → 499 → 1,377 ms —
3.6x behind drift at 1M, though still ahead of isar
(1,916 ms) and objectbox (1,782 ms) at 1M.
A SQL `SUM` over an expression of the booking day is the one workload a
document API structurally cannot match; if year reports matter, mirror the
column into your own SQL side or pre-aggregate.

### Status search (p50)

Cocoon's composite `(status, bookedOn)` index: 1.30 → 1.52 → 1.48 → 1.42 ms,
flat at every size. drift 0.76 → 0.84 → 0.80 → 0.82 ms (1.7x gap, the usual
document-layer tax). Everything without that composite grows with the
data: isar 1.09 → 6.85 → 21 → 84 ms, objectbox 0.49 → 6.21 → 19 → 66 ms,
hive 5.42 → 67 → 198 → 608 ms, sembast 6.95 → 116 → 333 → 1,171 ms — at 1M Cocoon is
429x ahead of Hive and 827x ahead of sembast.

### Read-while-write (one write every 10 ms, 200 latest-50 reads)

Cocoon's p95 stays at 2.57 → 2.89 → 3.01 → 3.53 ms — WAL readers never queue
behind the writer. drift runs its statements on one background isolate, so
reads queue behind writes: 4.24 → 5.22 → 4.67 → 4.96 ms — Cocoon is measurably
the better citizen under concurrent writes. isar and objectbox are fine at
10k (1.39 / 1.00 ms) and grow with the store
(18 / 16 ms at 300k). hive and sembast, re-ranking full
stores, climb into the hundreds of ms (679 / 1,000 ms at 1M).

### Restore 300k txns from the NDJSON backup

The same 300k restore at every size, and Cocoon is the slowest engine at
every size: cocoon 28 → 38 → 36 → 33 s, hive 3.29 → 3.33 → 3.13 → 3.03 s,
isar 5.35 → 5.02 → 4.83 → 4.77 s, objectbox 4.80 → 4.95 → 4.96 → 4.80 s, drift
14 → 15 → 14 → 14 s, sembast 16 → 19 → 14 → 14 s. At 1M-sized
databases that is 33.0 s vs hive 3.0 s
(10.9x) and drift 13.9 s (2.4x).
The restore pays the import cost per row — wire decode, two index rows,
change log, fsynced commits — with no cache to amortize it.

### Memory

Floor: bare `dart run` of this seven-engine harness = 431 MB RSS /
peak 451 MB. Everything below is minus that floor.

**After open** — cocoon 517 → 518 → 508 → 514 MB over the floor from
10k to 1M (flat), drift 515 → 497 → 516 → 515 MB, isar
482 → 487 → 487 → 484 MB, objectbox 495 → 488 → 497 → 483 MB,
hive 564 → 637 → 1,103 → 2,664 MB, sembast 416 → 588 → 983 → 2,358 MB.

**After the read workloads** (200 latest-50s across accounts, a monthly
total, 1,000 gets) — cocoon 421 → 422 → 430 → 427 MB: at or below the
floor at every size, i.e. nothing in the engine grows with the data. drift
405 → 386 → 417 → 403 MB (the leanest). isar grows to 262 MB
at 1M, objectbox to 155 MB at 300k (539 MB at 1M),
hive to 2,214 MB and sembast to 2,242 MB — both hold every
record in RAM, roughly 2.3 KB per txn at 1M.

**Peak RSS** — the noisiest signal (the harness's own JIT transient peaks
at 451 MB); see the tables. The after-reads row above is the one
that tracks the engines, and there Cocoon is flat and the store-everything
engines are not.

### File size

cocoon 8.57 → 44 → 119 → 375 MB. Cheaper: drift
2.20 → 22 → 67 → 224 MB (cocoon is 1.7x at 1M — two index tables plus the
change log), sembast 2.68 → 27 → 80 → 268 MB, isar 5.00 → 35 → 85 → 265 MB, hive
3.05 → 31 → 92 → 305 MB. More expensive: objectbox 6.79 → 64 → 186 → 609 MB —
ObjectBox files are bigger than Cocoon's from 100k up.

## Anything that looks wrong

- RSS is allocator-noisy in both directions: after-open sits ~+80 MB over
  the floor for the SQLite family while after-reads lands *below* the
  floor. The floor itself is this harness's seven-engine kernel, ~150 MB
  heavier than `cocoon_bench`'s. Within a row the floor cancels out and
  the cross-size flatness is the signal; absolute MB are not.
- The restore row is the same 300k work at every size, so its wobble
  (cocoon 27.9 → 38.2 → 35.8 → 33.0 s) is disk-cache state, not scaling.
- isar's gets-by-id collapse (2,170 ms for 1,000 docs at 300k, worse at
  1M) reproduces across all three runs; we measure the engine as it
  ships, no tuning attempted for any engine.
- drift's month-range collapse is LIMIT/OFFSET paging — the idiomatic
  port of the same Firestore-style paged query, not drift's best
  possible SQL (a hand-written keyset query would close most of the gap).
- The harness was fixed mid-matrix: its untimed sampler originally
  offset-paged ObjectBox's store to pick the random ids the
  gets/write/memory workloads read, and at 1M entities that walk alone
  outgrew the 10-minute box (the engine's timed reads were single-digit
  ms). The sampler now keyset-pages by internal id — the same visit
  order, so already-measured cells sampled identical documents — and
  ObjectBox's three sampling cells at 1M (rss, gets, write) were
  re-measured with it.
- The box reported 15,695 MB RAM during the first (busy) pass and
  27,405 MB during the re-measure (WSL2 dynamically assigns memory);
  nothing timed out and no cell shows memory pressure in its numbers.

## Reproduce

```sh
cd benchmarks/cocoon_rivals
tool/run_all.sh                  # 7 engines x 4 sizes x 13 ops; resumable,
                                 # skips every results/*.json already present
tool/run_all.sh 100000           # one size
python3 tool/make_results.py > RESULTS.md
python3 tool/check_verify.py \
    results/1000000_cocoon_verify.json results/1000000_drift_verify.json
dart test                        # 500-txn cross-engine contract smoke test
```

- Every cell is the median of 3 fresh `dart run` processes (memory never
  leaks between runs); the raw runs are in
  `results/<size>_<engine>_<op>.json`, the harness floor in
  `results/baseline.json`, machine info in `results/env.json`.
- A 10-minute box caps each single run; nothing timed out at any size.
- Run it on a quiet box: the first pass collided with an Android emulator
  + Gradle build and every cell inside those windows was re-measured
  (see `results/BUSY_WINDOWS.txt` and the note above).
- The full matrix is several hours of wall clock on the machine above;
  a single size is roughly a quarter of it. `verify` cells are untimed
  correctness dumps, one per engine and size, diffed against cocoon by
  `tool/check_verify.py` before any timing counts.
