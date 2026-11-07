# Cocoon vs sembast — finance-shaped benchmark

Cocoon's reason to exist is bounded RAM and fast indexed reads on a big
history. This is the honest measurement of that claim, against sembast (the
default pure-Dart choice) on data shaped like Finance Sync: 20 accounts
sharing 10k / 100k / 300k transactions over five years, each with a
`yyyymmdd` booking day, minor-unit amount, enum status, labels, 0-3 embedded
splits and 0-4 string map entries, under the same indexes Finance Sync would
declare (`['accountId', '-bookedOn']`, `['status', 'bookedOn']`).

Neither side is tuned. sembast gets a plain `txns` store with an
`accountId` field — its normal way — and its own transactions for the bulk
import. Cocoon runs its defaults: `Durability.full`, the 2000-document
cache, the change log on. Both engines import the identical seeded dataset.

Every number below is the median of 3 runs, each run a fresh `dart run`
process (`bin/bench.dart --engine … --size … --op …`), so memory never leaks
between runs. No run hit the 10-minute box; none timed out.

## Machine

- CPU: Intel(R) Core(TM) Ultra 5 325 (8 cores)
- RAM: 15,695 MB
- Dart: 3.13.7
- SQLite: 3.53.4
- WSL2 container on Windows; results/*.json holds every raw run.

## 10,000 txns

| import (median of 3) | Cocoon | sembast |
|---|---|---|
| time | 1,190 ms | 588 ms |
| file size | 8.28 MB | 2.68 MB |

| open + memory | Cocoon | sembast |
|---|---|---|
| cold open, process start to first query | 108 ms | 203 ms |
| RSS right after open | 261 MB | 300 MB |
| peak RSS after the read ops | 329 MB | 329 MB |

| latest 50 txns of one account (200 queries/run) | Cocoon | sembast |
|---|---|---|
| p50 | 679 us | 3,742 us |
| p95 | 2,073 us | 4,587 us |

| one account's monthly totals, one year | Cocoon | sembast |
|---|---|---|
| time | 13.0 ms | 28.0 ms |
| docs scanned | 100 | 100 |
| grand total (minor units) | 3,560,437 | 3,560,437 |

| 1,000 random gets by id | Cocoon | sembast |
|---|---|---|
| total time | 219 ms | 9.00 ms |
| found | 1,000 | 1,000 |

| single write (200 writes/run) | Cocoon | sembast |
|---|---|---|
| p50 | 2,147 us | 306 us |
| p95 | 2,791 us | 527 us |

## 100,000 txns

| import (median of 3) | Cocoon | sembast |
|---|---|---|
| time | 7,083 ms | 4,462 ms |
| file size | 39.3 MB | 26.8 MB |

| open + memory | Cocoon | sembast |
|---|---|---|
| cold open, process start to first query | 229 ms | 936 ms |
| RSS right after open | 335 MB | 538 MB |
| peak RSS after the read ops | 370 MB | 563 MB |

| latest 50 txns of one account (200 queries/run) | Cocoon | sembast |
|---|---|---|
| p50 | 669 us | 64,474 us |
| p95 | 1,845 us | 69,204 us |

| one account's monthly totals, one year | Cocoon | sembast |
|---|---|---|
| time | 60.0 ms | 116 ms |
| docs scanned | 980 | 980 |
| grand total (minor units) | 86,214,003 | 86,214,003 |

| 1,000 random gets by id | Cocoon | sembast |
|---|---|---|
| total time | 224 ms | 46.0 ms |
| found | 1,000 | 1,000 |

| single write (200 writes/run) | Cocoon | sembast |
|---|---|---|
| p50 | 2,032 us | 406 us |
| p95 | 2,820 us | 858 us |

## 300,000 txns

| import (median of 3) | Cocoon | sembast |
|---|---|---|
| time | 26,115 ms | 15,054 ms |
| file size | 108 MB | 80.5 MB |

| open + memory | Cocoon | sembast |
|---|---|---|
| cold open, process start to first query | 510 ms | 2,802 ms |
| RSS right after open | 477 MB | 1,074 MB |
| peak RSS after the read ops | 502 MB | 1,117 MB |

| latest 50 txns of one account (200 queries/run) | Cocoon | sembast |
|---|---|---|
| p50 | 704 us | 215,084 us |
| p95 | 2,030 us | 227,993 us |

| one account's monthly totals, one year | Cocoon | sembast |
|---|---|---|
| time | 91.0 ms | 272 ms |
| docs scanned | 2,984 | 2,984 |
| grand total (minor units) | 205,794,255 | 205,794,255 |

| 1,000 random gets by id | Cocoon | sembast |
|---|---|---|
| total time | 236 ms | 114 ms |
| found | 1,000 | 1,000 |

| single write (200 writes/run) | Cocoon | sembast |
|---|---|---|
| p50 | 2,369 us | 291 us |
| p95 | 4,314 us | 522 us |

## Where Cocoon wins

**Indexed reads, by a mile, and the gap grows with the data.** Latest-50 for
one account is 679 us vs 3.7 ms at 10k (5x), 669 us vs 64 ms at 100k (96x),
704 us vs 215 ms at 300k (305x). Cocoon's p50 is *flat* while the dataset
grows 30x — the composite index `(accountId, bookedOn DESC)` serves a keyset
range scan. sembast's store has no index; every `find` with a filter and a
sort order scans the whole store, so its time grows linearly (3.7 → 64 →
215 ms for 10k → 100k → 300k). The measured scaling *is* the evidence: sembast's
query time multiplied ~58x for 30x the data.

**Cold open.** sembast parses its whole log file into RAM on open: 203 ms →
936 ms → 2.8 s. Cocoon opens the SQLite file and reads nothing until asked:
108 → 229 → 510 ms, most of that the `dart run` kernel load both engines
share. At 300k that is 5.5x faster to first answer.

**Memory at scale: Cocoon uses less, but these RSS numbers are inflated.**
RSS right after open: 477 MB vs 1,074 MB at 300k, peak 502 vs 1,117 MB; at
100k 335 vs 538 MB. Caveat found at review: `bin/bench.dart` builds the whole
typed dataset in RAM (line 74) for *every* op, including `open` and `rss`, so
both columns include the harness's own copy of the data, and that copy grows
with the size. So Cocoon's RSS rising 261 -> 335 -> 477 MB does not show
whether the engine itself stays flat; the difference between the columns
(sembast holding every decoded record, Cocoon a 2000-doc cache plus SQLite's
page cache) is the real signal. A re-measurement without the dataset in
memory is pending.

**Monthly totals** (pages an indexed range query and sums in Dart; sembast
uses a Finder; neither engine has SQL aggregates): Cocoon 13 vs 28 ms,
60 vs 116 ms, 91 vs 272 ms — 2-3x faster at every size, with identical
scanned counts and identical totals (a cross-engine correctness check that
ran at every size).

## Where Cocoon loses

**Bulk import: 1.6-2x slower, and the file is bigger.** 1,190 vs 588 ms at
10k, 26.1 s vs 15.1 s at 300k; on disk 8.3 vs 2.7 MB (3.1x) at 10k, narrowing
to 108 vs 80.5 MB (1.3x) at 300k. Why: sembast appends one JSON line per
record. Cocoon encodes to wire bytes and writes one row per document *plus*
one row per document in each of the two index tables *plus* change-log rows
(`keepChanges` defaults to true), and commits a batch with an fsync
(`Durability.full`). That is 4 rows of write amplification per document
bought for the indexed reads above. If a sync tool ever needs faster bulk
loads, `Durability.normal` and `keepChanges: false` are both already options
on `CocoonOptions`.

**Point gets by id: 2-24x slower.** 219 vs 9 ms at 10k, 224 vs 46 ms at
100k, 236 vs 114 ms at 300k. sembast's record id *is* its in-memory map key,
so a get is a hash lookup. Cocoon parses the path, resolves the adapter and
runs a SQLite SELECT by path per document; the 2000-document LRU cache
almost never hits on random ids over a 300k history. That is the bounded-RAM
trade working as designed — raise `cacheSize` and the gap narrows at the
cost of RAM — but at defaults it is a real loss.

**Single writes: 5-7x slower.** p50 2.1-2.4 ms vs 0.29-0.41 ms at every
size. Why: Cocoon's default `Durability.full` is `PRAGMA synchronous =
FULL` — every commit fsyncs the WAL, so nothing is lost on power loss.
sembast's io factory appends the record to its log and never fsyncs per
record, so it trades durability for speed by default. Cocoon's
`Durability.normal` (safe with WAL against application crashes, may lose the
last transactions on power loss) exists for exactly this workload; measuring
it was out of scope here (defaults vs defaults), so it is documented, not
benchmarked.

## Anything that looks wrong

- Both engines show a ~260-300 MB RSS floor at 10k: the Dart VM plus the
  harness's in-memory copy of the dataset, which `open`/`rss` runs build too
  (see the memory caveat above). Pending re-measurement.
- Cocoon's cold open grows 108 → 229 → 510 ms across sizes. Engine-side open
  only grows 73 → 152 ms; the rest is harness/kernel noise plus more WAL to
  recover. Still 5.5x under sembast at 300k.
- Cocoon's single-write p95 grows from 2.8 ms (100k) to 4.3 ms (300k): the
  two index B-trees get deeper and the change log longer. Not an anomaly,
  worth watching on low-end flash.
- sembast's gets non-monotonic across sizes (9 → 46 → 114 ms) tracks its
  in-memory store growing; nothing anomalous.

## Reproduce

```sh
cd packages/cocoon_bench
tool/run_all.sh                 # 10k + 100k + 300k, ~15 min
tool/run_all.sh 10000           # one size
```

Raw numbers: `results/<size>_<engine>_<op>.json` (3 runs each), machine info
in `results/env.json`. Correctness before speed: `dart test` runs a smoke
test that imports a 500-txn dataset into both engines and asserts identical
latest-50 ids and identical monthly totals.
