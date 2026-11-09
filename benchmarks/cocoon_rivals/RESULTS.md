# Cocoon vs the real local-database rivals

An honest benchmark of Cocoon against the engines a big on-device app would actually pick — drift (plain SQLite, the speed limit), Isar, ObjectBox, Hive CE and sembast — on finance-shaped data at up to 1,000,000 transactions.

Workloads are the ones a big finance app runs: bulk import, cold open, one account's latest-50, monthly totals, random gets, single writes, plus the all-accounts shapes (month range, year report, status search), the query-specialist shapes (bigspend, amount range, pending month, deep page, counts), read-while-write, and a 300k-restore from an NDJSON backup. Every run is a fresh process; every number is the median of three runs; every memory number is the run's own share — the RSS rows minus the bare harness's RSS, the peak rows minus the bare harness's peak. A cell says `timeout` when the 10-minute box cut the run off. Correctness first: a 500-txn smoke test asserts every engine returns identical, contract-ordered results for every workload (`dart test` here), and at every measured size a `verify` dump is diffed against Cocoon's before any timing counts.

### The workloads

- **bigspend** — the 50 largest debits across all accounts: `amountMinor ASC` (most negative first), ties by string id `ASC`, limit 50; 50 runs, p50/p95. No amount filter: with the dataset's distribution the 50 smallest amounts are always debits, and every engine must return the same ids.
- **amountrange** — every txn with `amountMinor` in the fixed band [150000, 166500) minor units, chosen once from the dataset's distribution so it returns ~1% of the rows (measured 0.96% at 10k, 1.00% at 100k, 1.00% at 300k txns; the amounts are ±(100..990099), 40% negative, and the band sits on the credit side): all accounts, `amountMinor ASC`, ties by id `ASC`, paged by 100. Reports elapsed ms, pages, count.
- **pendingmonth** — the compound filter: `status == pending` AND `bookedOn` in 202406 (rangeMonthKey), all accounts, `bookedOn ASC`, ties by id `ASC`, paged by 100 — served by the `(status, bookedOn)` index where one exists. Reports elapsed ms, pages, count.
- **deeppage** — one account's history newest-first, 20 pages of 50 by the engine's own paging idiom (keyset cursor for Cocoon; offset paging for drift, Isar, ObjectBox and sembast — their documented idiom; the in-RAM list slice for Hive). Run over 10 accounts; reports per-page p50/p95 and the page-20 duration (its median over the accounts that walked that deep) — whether paging stays flat deep into history.
- **count** — (1) `pending` txns across all accounts, (2) one account's (a05) txns in the 2024 report year: Cocoon `query.count()`, drift `SELECT count(*)`, isar `.count()`, objectbox `query.count()`, hive/sembast a scan; 20 runs each, p50/p95 per shape.

### The cost metrics

Every op also reports `peakRssBytes` (the process high-water mark), `cpuMs` (the process's user+sys CPU over the op's measured section — the `/proc/self/stat` utime+stime delta at `getconf CLK_TCK` ticks/s) and `diskWriteBytes` (the `/proc/self/io` `write_bytes` delta over the same section, so native and isolate threads count). `import` adds `writeAmplification` = diskWriteBytes / final file size. The cpu/io sections are the same sections the wall-time metrics cover (open/seed/sample setup stays outside), except that import and restore bracket their engine's whole call (the engine's untimed accounts / fresh open live inside). `cpuMs` can legitimately be 0 for very fast ops at the kernel's tick granularity. `diskWriteBytes` needs kernel io accounting (`/proc/self/io`); kernels built without `CONFIG_TASK_IO_ACCOUNTING` — this WSL2 box's microsoft-standard kernel among them — have no per-process disk numbers, the key is omitted and the disk rows below render as '—'; on mainline/Android kernels they fill in. The tables use the cost metrics for import (CPU, disk written, write amplification) and for the two peak-RSS rows (import, restore).

Raw SQLite itself is mapped separately in [CEILING.md](CEILING.md): what the fastest possible load of Cocoon's real table costs and what each lever (deferred indexes, one transaction, change-log granularity, synchronous, rowid keys) buys at 1M.

## Machine

- Dart 3.13.7, SQLite 3.54.1
- Intel(R) Core(TM) Ultra 5 325, 8 cores, 27405 MB RAM
- Harness floor: 450 MB RSS, peak 476 MB

## 10,000 transactions

| Workload | cocoon | cocoon-normal | drift | isar | objectbox | hive | sembast |
|---|---|---|---|---|---|---|---|
| Import (s) | 0.2 | 0.2 | 0.2 | 0.1 | 0.2 | 0.1 | 0.6 |
| Bulk import (s) | 0.2 | 0.2 | 0.2 | 0.1 | 0.1 | 0.1 | 0.6 |
| File size (MB) | 12.3 | 12.3 | 2.3 | 10.0 | 7.4 | 3.0 | 2.7 |
| Cold open (ms) | 153 | 152 | 138 | 138 | 133 | 188 | 256 |
| RSS after open, − floor (MB) | 92.9 | 85.0 | 71.0 | 57.7 | 60.1 | -4.5 | -26.9 |
| RSS after reads, − floor (MB) | -16.2 | -10.2 | -31.6 | -51.5 | -44.3 | -21.6 | -17.5 |
| Peak RSS, − floor peak (MB) | 73.4 | 72.3 | 71.2 | 75.2 | 86.9 | 94.2 | 75.9 |
| Latest-50 p50 (ms) | 0.7 | 0.6 | 0.5 | 0.9 | 0.3 | 3.1 | 4.1 |
| Latest-50 p95 (ms) | 2.4 | 2.2 | 1.3 | 1.6 | 0.8 | 4.7 | 5.9 |
| Monthly totals (ms) | 19 | 20 | 14 | 21 | 10 | 5 | 48 |
| 1,000 random gets (ms) | 150 | 135 | 107 | 388 | 15 | 1 | 9 |
| Single write p50 (µs) | 2016 | 553 | 3119 | 1139 | 743 | 114 | 341 |
| Single write p95 (µs) | 2881 | 953 | 3931 | 1802 | 1225 | 266 | 602 |
| Month range, all accounts (ms) | 32 | 32 | 17 | 25 | 12 | 10 | 52 |
| Year report, all accounts (ms) | 80 | 77 | 17 | 77 | 20 | 9 | 49 |
| Status search p50 (ms) | 1.3 | 1.3 | 0.8 | 1.1 | 0.5 | 3.6 | 6.1 |
| Status search p95 (ms) | 3.8 | 3.5 | 2.3 | 2.6 | 1.7 | 7.5 | 8.4 |
| Bigspend p50 (ms) | 1.3 | 1.3 | 1.0 | 0.7 | 0.5 | 5.8 | 39.8 |
| Bigspend p95 (ms) | 3.6 | 3.7 | 4.1 | 1.7 | 1.4 | 8.4 | 45.6 |
| Amount range, all accounts (ms) | 20 | 19 | 13 | 20 | 12 | 10 | 46 |
| Pending month, all accounts (ms) | 12 | 12 | 10 | 23 | 11 | 10 | 44 |
| Deep page p50 (ms) | 1.1 | 1.0 | 0.7 | 0.9 | 0.3 | 0.0 | 4.6 |
| Deep page p95 (ms) | 3.7 | 3.2 | 2.2 | 1.8 | 0.8 | 4.7 | 6.8 |
| Deep page 20 (ms) | — | — | — | — | — | — | — |
| Count pending p50 (ms) | 0.4 | 0.5 | 0.1 | 1.1 | 0.2 | 0.9 | 3.9 |
| Count year p50 (ms) | 0.5 | 0.5 | 0.1 | 1.1 | 0.1 | 0.9 | 3.7 |
| Read-while-write p95 (ms) | 2.5 | 2.3 | 5.2 | 1.9 | 0.9 | 5.0 | 6.2 |
| Restore 300k from NDJSON (s) | 15.1 | 14.4 | 23.1 | 6.5 | 6.4 | 3.2 | 14.6 |
| Import peak RSS, − floor peak (MB) | 67.5 | 75.5 | 68.9 | 64.9 | 80.8 | 69.8 | 69.3 |
| Import CPU (s) | 0.6 | 0.5 | 0.5 | 0.4 | 0.5 | 0.4 | 0.8 |
| Import disk written (MB) | 12.4 | 12.3 | 8.8 | 8.7 | 10.2 | 3.1 | 2.7 |
| Import write amplification (x) | 1.01 | 1.00 | 3.79 | 0.87 | 1.38 | 1.00 | 1.00 |
| Restore peak RSS, − floor peak (MB) | 66.6 | 63.6 | 68.6 | 78.9 | 130.2 | 563.9 | 501.6 |

## 100,000 transactions

| Workload | cocoon | cocoon-normal | drift | isar | objectbox | hive | sembast |
|---|---|---|---|---|---|---|---|
| Import (s) | 2.4 | 2.2 | 3.5 | 1.3 | 2.0 | 0.7 | 4.6 |
| Bulk import (s) | 1.1 | 1.1 | 1.4 | 0.4 | 0.6 | 0.7 | 4.6 |
| File size (MB) | 57.4 | 57.4 | 23.5 | 40.0 | 69.0 | 30.5 | 26.8 |
| Cold open (ms) | 153 | 147 | 148 | 130 | 132 | 678 | 910 |
| RSS after open, − floor (MB) | 93.0 | 93.6 | 90.6 | 55.1 | 67.0 | 197.8 | 153.0 |
| RSS after reads, − floor (MB) | -12.1 | -2.4 | -24.6 | -18.0 | 17.8 | 207.4 | 192.2 |
| Peak RSS, − floor peak (MB) | 71.4 | 72.7 | 73.6 | 110.6 | 143.4 | 180.0 | 164.8 |
| Latest-50 p50 (ms) | 0.7 | 0.7 | 0.5 | 4.6 | 3.7 | 67.2 | 67.1 |
| Latest-50 p95 (ms) | 2.3 | 2.4 | 1.4 | 6.3 | 4.8 | 74.3 | 77.4 |
| Monthly totals (ms) | 63 | 68 | 41 | 40 | 22 | 26 | 127 |
| 1,000 random gets (ms) | 137 | 137 | 91 | 954 | 11 | 3 | 68 |
| Single write p50 (µs) | 1980 | 526 | 3151 | 1256 | 737 | 109 | 379 |
| Single write p95 (µs) | 2586 | 824 | 4097 | 1768 | 1248 | 243 | 692 |
| Month range, all accounts (ms) | 85 | 85 | 72 | 109 | 143 | 66 | 1160 |
| Year report, all accounts (ms) | 233 | 229 | 43 | 198 | 159 | 45 | 161 |
| Status search p50 (ms) | 1.2 | 1.3 | 0.8 | 5.8 | 5.2 | 67.4 | 100.8 |
| Status search p95 (ms) | 3.2 | 4.0 | 2.3 | 8.3 | 7.4 | 72.7 | 109.0 |
| Bigspend p50 (ms) | 1.2 | 1.3 | 0.8 | 0.7 | 6.7 | 68.5 | 881.4 |
| Bigspend p95 (ms) | 4.0 | 4.0 | 2.2 | 1.7 | 8.4 | 73.5 | 989.4 |
| Amount range, all accounts (ms) | 70 | 61 | 43 | 38 | 86 | 67 | 642 |
| Pending month, all accounts (ms) | 32 | 31 | 21 | 35 | 27 | 67 | 153 |
| Deep page p50 (ms) | 0.8 | 0.8 | 1.1 | 4.8 | 2.8 | 0.0 | 67.2 |
| Deep page p95 (ms) | 2.6 | 2.5 | 2.1 | 6.5 | 4.4 | 0.0 | 75.2 |
| Deep page 20 (ms) | 0.9 | 0.8 | 1.7 | 4.9 | 2.8 | 0.0 | 66.6 |
| Count pending p50 (ms) | 0.7 | 0.7 | 0.3 | 5.5 | 5.7 | 21.0 | 50.2 |
| Count year p50 (ms) | 0.6 | 0.5 | 0.2 | 5.0 | 2.2 | 20.6 | 45.7 |
| Read-while-write p95 (ms) | 2.6 | 2.5 | 4.5 | 6.3 | 4.8 | 67.2 | 99.8 |
| Restore 300k from NDJSON (s) | 12.9 | 12.8 | 16.2 | 6.3 | 6.5 | 3.1 | 16.2 |
| Import peak RSS, − floor peak (MB) | 118.2 | 125.0 | 117.6 | 115.3 | 120.4 | 144.5 | 114.3 |
| Import CPU (s) | 2.1 | 2.0 | 2.2 | 1.0 | 1.1 | 1.1 | 3.5 |
| Import disk written (MB) | 732.1 | 731.7 | 636.3 | 446.7 | 361.2 | 30.5 | 26.9 |
| Import write amplification (x) | 12.75 | 12.75 | 27.06 | 11.17 | 5.24 | 1.00 | 1.00 |
| Restore peak RSS, − floor peak (MB) | 74.3 | 70.0 | 63.8 | 77.3 | 131.5 | 580.9 | 498.5 |

## 300,000 transactions

| Workload | cocoon | cocoon-normal | drift | isar | objectbox | hive | sembast |
|---|---|---|---|---|---|---|---|
| Import (s) | 11.4 | 12.3 | 29.3 | 8.1 | 5.4 | 2.3 | 14.6 |
| Bulk import (s) | 3.4 | 3.4 | 4.9 | 1.5 | 2.0 | 2.2 | 14.1 |
| File size (MB) | 161.0 | 161.0 | 70.9 | 100.0 | 191.6 | 91.6 | 80.5 |
| Cold open (ms) | 150 | 147 | 151 | 245 | 148 | 1640 | 2562 |
| RSS after open, − floor (MB) | 89.7 | 70.5 | 93.3 | 23.3 | 72.6 | 668.5 | 547.9 |
| RSS after reads, − floor (MB) | -5.7 | -23.4 | -18.1 | 65.0 | 138.3 | 677.3 | 641.1 |
| Peak RSS, − floor peak (MB) | 68.2 | 64.3 | 75.3 | 158.4 | 183.4 | 650.0 | 634.8 |
| Latest-50 p50 (ms) | 0.8 | 0.7 | 0.5 | 18.0 | 13.0 | 249.3 | 234.5 |
| Latest-50 p95 (ms) | 2.4 | 2.4 | 1.3 | 25.2 | 14.9 | 318.1 | 246.0 |
| Monthly totals (ms) | 105 | 107 | 67 | 74 | 44 | 63 | 335 |
| 1,000 random gets (ms) | 122 | 113 | 96 | 3283 | 11 | 4 | 243 |
| Single write p50 (µs) | 1942 | 495 | 3652 | 1732 | 798 | 115 | 343 |
| Single write p95 (µs) | 2780 | 837 | 5406 | 2416 | 1151 | 270 | 643 |
| Month range, all accounts (ms) | 140 | 138 | 296 | 643 | 1181 | 185 | 9978 |
| Year report, all accounts (ms) | 464 | 457 | 105 | 586 | 551 | 120 | 438 |
| Status search p50 (ms) | 1.2 | 1.3 | 0.8 | 22.7 | 19.9 | 203.4 | 362.9 |
| Status search p95 (ms) | 5.4 | 4.0 | 3.4 | 26.2 | 22.1 | 223.6 | 373.4 |
| Bigspend p50 (ms) | 1.4 | 1.4 | 0.9 | 0.7 | 21.7 | 211.6 | 2896.8 |
| Bigspend p95 (ms) | 3.4 | 3.7 | 2.7 | 1.4 | 24.7 | 234.0 | 3306.6 |
| Amount range, all accounts (ms) | 118 | 111 | 208 | 85 | 713 | 194 | 5911 |
| Pending month, all accounts (ms) | 56 | 56 | 38 | 149 | 145 | 185 | 1107 |
| Deep page p50 (ms) | 0.8 | 0.8 | 1.2 | 18.2 | 13.8 | 0.0 | 242.5 |
| Deep page p95 (ms) | 2.7 | 2.4 | 2.3 | 22.8 | 15.6 | 0.1 | 276.2 |
| Deep page 20 (ms) | 0.7 | 0.8 | 1.7 | 18.4 | 14.2 | 0.0 | 244.4 |
| Count pending p50 (ms) | 1.2 | 1.1 | 0.7 | 23.9 | 19.3 | 64.5 | 172.3 |
| Count year p50 (ms) | 0.5 | 0.5 | 0.2 | 17.9 | 12.6 | 63.0 | 160.3 |
| Read-while-write p95 (ms) | 2.5 | 2.7 | 4.4 | 20.7 | 16.9 | 226.6 | 395.1 |
| Restore 300k from NDJSON (s) | 13.1 | 14.1 | 21.9 | 6.5 | 10.3 | 3.2 | 15.7 |
| Import peak RSS, − floor peak (MB) | 216.3 | 185.9 | 151.6 | 261.7 | 342.6 | 537.5 | 488.0 |
| Import CPU (s) | 8.8 | 8.6 | 9.3 | 5.6 | 4.0 | 3.6 | 11.1 |
| Import disk written (MB) | 4752.8 | 4751.9 | 4342.1 | 2045.9 | 1699.6 | 91.7 | 81.0 |
| Import write amplification (x) | 29.53 | 29.52 | 61.22 | 20.46 | 8.87 | 1.00 | 1.01 |
| Restore peak RSS, − floor peak (MB) | 69.2 | 68.4 | 66.0 | 74.2 | 132.1 | 572.4 | 498.7 |

## 1,000,000 transactions

| Workload | cocoon | cocoon-normal | drift | isar | objectbox | hive | sembast |
|---|---|---|---|---|---|---|---|
| Import (s) | 77.9 | 73.7 | 119.5 | 35.1 | 32.2 | 8.5 | 45.2 |
| Bulk import (s) | 12.6 | 13.0 | 18.7 | 5.7 | 8.8 | 7.9 | 46.5 |
| File size (MB) | 425.8 | 425.8 | 236.8 | 315.0 | 615.4 | 305.4 | 268.3 |
| Cold open (ms) | 152 | 158 | 141 | 185 | 182 | 5397 | 8015 |
| RSS after open, − floor (MB) | 82.0 | 90.2 | 80.9 | 56.1 | 71.0 | 2238.4 | 1928.8 |
| RSS after reads, − floor (MB) | 2.0 | -1.3 | -24.5 | 304.5 | 545.8 | 2057.1 | 2297.6 |
| Peak RSS, − floor peak (MB) | 72.7 | 68.2 | 69.2 | 346.1 | 602.1 | 2496.2 | 2270.5 |
| Latest-50 p50 (ms) | 0.7 | 0.7 | 0.5 | 55.5 | 44.4 | 710.5 | 796.3 |
| Latest-50 p95 (ms) | 2.4 | 2.6 | 1.3 | 64.3 | 48.1 | 745.1 | 820.2 |
| Monthly totals (ms) | 180 | 181 | 104 | 127 | 117 | 291 | 808 |
| 1,000 random gets (ms) | 94 | 92 | 79 | 6656 | 10 | 5 | 573 |
| Single write p50 (µs) | 1885 | 450 | 2975 | 1241 | 818 | 112 | 313 |
| Single write p95 (µs) | 2803 | 750 | 3835 | 1740 | 1759 | 244 | 509 |
| Month range, all accounts (ms) | 308 | 307 | 2588 | 6534 | 12478 | 621 | 102646 |
| Year report, all accounts (ms) | 1419 | 1376 | 358 | 1928 | 1830 | 326 | 1131 |
| Status search p50 (ms) | 1.4 | 1.4 | 0.8 | 85.3 | 65.6 | 645.2 | 1242.3 |
| Status search p95 (ms) | 4.1 | 3.5 | 2.3 | 96.2 | 70.6 | 662.1 | 1271.0 |
| Bigspend p50 (ms) | 1.3 | 1.4 | 0.8 | 0.7 | 69.1 | 638.6 | 10374.8 |
| Bigspend p95 (ms) | 4.1 | 4.1 | 2.1 | 1.6 | 73.9 | 664.3 | 10681.1 |
| Amount range, all accounts (ms) | 218 | 213 | 945 | 459 | 7725 | 588 | 57372 |
| Pending month, all accounts (ms) | 98 | 92 | 88 | 1098 | 1159 | 555 | 7667 |
| Deep page p50 (ms) | 0.8 | 0.8 | 1.2 | 57.9 | 45.8 | 0.0 | 799.3 |
| Deep page p95 (ms) | 2.5 | 2.6 | 2.4 | 66.5 | 48.7 | 0.0 | 826.6 |
| Deep page 20 (ms) | 0.9 | 0.7 | 1.8 | 57.8 | 46.8 | 0.0 | 800.8 |
| Count pending p50 (ms) | 3.6 | 3.5 | 2.4 | 62.1 | 64.4 | 183.3 | 468.4 |
| Count year p50 (ms) | 0.7 | 0.7 | 0.3 | 54.7 | 44.1 | 177.4 | 435.3 |
| Read-while-write p95 (ms) | 3.2 | 2.5 | 4.3 | 67.1 | 50.4 | 760.8 | 1049.7 |
| Restore 300k from NDJSON (s) | 13.0 | 14.1 | 18.0 | 6.2 | 6.4 | 3.1 | 14.6 |
| Import peak RSS, − floor peak (MB) | 686.1 | 684.1 | 622.3 | 952.0 | 1223.4 | 1939.6 | 1780.4 |
| Import CPU (s) | 43.9 | 42.9 | 40.0 | 16.2 | 15.2 | 13.6 | 33.8 |
| Import disk written (MB) | 26147.1 | 26144.6 | 23705.4 | 8699.0 | 7179.5 | 305.5 | 269.1 |
| Import write amplification (x) | 61.41 | 61.40 | 100.11 | 27.62 | 11.67 | 1.00 | 1.00 |
| Restore peak RSS, − floor peak (MB) | 65.7 | 72.2 | 50.6 | 76.0 | 128.4 | 587.0 | 502.1 |

## Verdicts

Written by hand from the tables above (matrix v2, 9-10 Nov 2026). Every number quoted here
comes from `results/*.json`, the same files `tool/make_results.py` reads.

### The short version

**Cocoon wins the things it exists for.** At 1M transactions every indexed query an app runs
answers in 0.7-3.6 ms (one account's latest 50, the latest pending across accounts, the 50
biggest debits, counts, reads while a sync writes), flat from 10k to 1M, while the log stores
pay for the whole history on every query: one account's latest 50 is 0.7 ms against Hive's
711 ms and sembast's 796 ms. Its RAM after the reads stays at the harness floor (+2 MB) where
Hive holds 2.1 GB and sembast 2.3 GB, and its engine open is 82 ms where Hive needs 5.2 s.

**It loses where it should be honest about it.** Against drift (plain SQLite, the speed
limit) the indexed reads cost 1.4-2x: that gap is decoding documents into typed objects. The
year report is 4x behind drift and Hive (no aggregate pushdown: Cocoon sums in Dart), monthly
totals 1.7x behind drift, gets by id 9x behind ObjectBox and 19x behind Hive. A bulk load
through `bulkWriter()` (12.6 s at 1M) beats drift and sembast but trails Isar 2.2x, Hive
1.6x and ObjectBox 1.4x through their own best bulk APIs.

### Bulk loads

Two rows, on purpose. **Import** is like-for-like: every engine commits every 1,000 rows. At
1M Cocoon takes 77.9 s against drift's 119.5 s; Isar 35.1 s, ObjectBox 32.2 s, Hive 8.5 s.
(The first v2 pass measured Cocoon's import at 103.0 s on identical work: 26.1 GB written
both times. Treat import wall times on this WSL2 disk as +-25%.) The cost is the commit
pattern, not the document layer: every commit rewrites index pages scattered over four
secondary indexes, so the import writes 61x the final file size to disk (drift 100x, Hive and
sembast 1x). `CEILING.md` measures the same thing with raw SQLite: 70.9 s at 1,000 rows per
commit.

**Bulk import** gives every engine its best documented bulk API: Cocoon `bulkWriter()`
(10,000-row chunks, secondary indexes built once at close), drift one `batch`, Isar one
`writeTxn` + `putAll`, ObjectBox one `putMany`, Hive one `putAll`, sembast one transaction.
At 1M: Isar 5.7 s, Hive 7.9 s, ObjectBox 8.8 s, **Cocoon 12.6 s**, drift 18.7 s, sembast
46.5 s. Cocoon is 6x faster than its own 1,000-per-commit import and within ~1.3x of raw
SQLite's deferred-index ceiling (9.5 s).

### Cold open

The SQLite-family engines open flat: Cocoon's own open plus first answer is 85 -> 79 -> 86
-> 82 ms over the four sizes, drift 72-80 ms. The log stores read their whole file first:
Hive 117 ms -> 5.2 s, sembast 189 ms -> 7.9 s. The table's "Cold open" row is measured from
process start; since step 12 it includes ~70 ms of the harness's cost meter for every engine.

### Queries at 1M

- **One account's latest 50**: Cocoon 0.7 ms, drift 0.5, ObjectBox 44, Isar 56, Hive 711,
  sembast 796.
- **20 pages deep into one account** (the whole walk): Cocoon 24 ms, drift 27 ms (offset
  paging re-reads every earlier page), Hive 714 ms, ObjectBox 923 ms, Isar 1.2 s, sembast
  16 s. Cocoon's keyset cursor keeps page 20 as cheap as page 1.
- **One month across all accounts, paged**: Cocoon 308 ms, drift 2.6 s, Isar 6.5 s,
  ObjectBox 12.5 s, sembast 103 s.
- **A 1% amount band, paged**: Cocoon 218 ms, Isar 459, Hive 588, drift 945, ObjectBox 7.7 s,
  sembast 57 s.
- **The 50 biggest debits**: Isar 0.7 ms, drift 0.8, Cocoon 1.3, ObjectBox 69, Hive 639,
  sembast 10.4 s.
- **Pending in one month (compound filter)**: drift 88 ms, Cocoon 98, Hive 555, Isar 1.1 s.
- **Counts**: Cocoon 3.6 ms for every pending txn (drift 2.4, Isar 62, Hive 183).
- **Year report**: Hive 326 ms, drift 358, sembast 1.1 s, Cocoon 1.4 s, ObjectBox 1.8 s,
  Isar 1.9 s. The next read-side step is aggregate pushdown (Firestore's `sum`/`count`
  aggregations) so this runs in SQL.
- **1,000 gets by id**: Hive 5 ms, ObjectBox 10, drift 79, Cocoon 94, sembast 573, Isar 6.7 s.

### Writes

One write at `Durability.full`: Cocoon 1,885 us p50, faster than drift's 2,975 us. At
`Durability.normal` (still crash-safe, may lose the last moments on power loss) 450 us. Hive
(112 us) and sembast (313 us) do not wait for the disk on each write; compare them with
`cocoon-normal`.

### Memory

After the read workloads at 1M: Cocoon +2 MB over the harness floor, drift at the floor,
Isar 305 MB, ObjectBox 546 MB, Hive 2.1 GB, sembast 2.3 GB. Peak during the 1M import is
similar for every engine (620-690 MB for the SQLite family, most of it the harness's own
dataset); Hive peaks at 1.9 GB.

### Known issues in this run

- **Isar's `bigspend` and `amountrange` at 100k and above** return the same rows as Cocoon
  with ties on equal amounts in a different order (Isar walks equal index keys in its own
  order, the contract says id ascending). Their timings are shown; the fix is pending.
- **Disk written** comes from the Foreman job's cgroup `io.stat` (this WSL2 kernel has no
  per-process io accounting), so it is only meaningful because the matrix runs one process at
  a time.
