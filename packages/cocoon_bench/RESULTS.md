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

The harness carries no data of its own: only `import` builds the typed
dataset, every other operation takes its account ids from the seed and its
random ids and values from the database itself (a seeded sample read from
the engine after open, outside the timed sections). A `baseline` operation
(`results/baseline.json`) reports what a bare `dart run` of the harness
costs with nothing opened — RSS 276 MB, peak 359 MB, the VM and kernel load
both engines share. "− baseline" below is the engine's own share. The
memory rows and the cold-open numbers were re-measured on this harness; the
first run built the whole dataset in every process, which inflated both
engines' open and memory numbers (and all of Cocoon's cold-open growth).

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

| open + memory (harness baseline: RSS 276 MB, peak 359 MB) | Cocoon | sembast |
|---|---|---|
| cold open, process start to first query | 80 ms | 186 ms |
| RSS right after open | 263 MB (−13 vs baseline) | 296 MB (+20) |
| RSS after the read ops | 312 MB (+36) | 307 MB (+31) |
| peak RSS | 341 MB (−18 vs baseline peak) | 335 MB (−24) |

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

| open + memory (harness baseline: RSS 276 MB, peak 359 MB) | Cocoon | sembast |
|---|---|---|
| cold open, process start to first query | 82 ms | 862 ms |
| RSS right after open | 263 MB (−12 vs baseline) | 476 MB (+200) |
| RSS after the read ops | 315 MB (+39) | 522 MB (+246) |
| peak RSS | 340 MB (−19 vs baseline peak) | 521 MB (+163) |

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

| open + memory (harness baseline: RSS 276 MB, peak 359 MB) | Cocoon | sembast |
|---|---|---|
| cold open, process start to first query | 82 ms | 2,359 ms |
| RSS right after open | 263 MB (−13 vs baseline) | 873 MB (+598) |
| RSS after the read ops | 314 MB (+39) | 980 MB (+704) |
| peak RSS | 336 MB (−23 vs baseline peak) | 980 MB (+621) |

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

## The two knobs

Both knobs are Cocoon defaults measured one at a time, same operations as
above, fresh process per run.

**Single writes at 100k** (200 writes/run, the write op above):

| configuration | p50 | p95 |
|---|---|---|
| defaults: `Durability.full`, `keepChanges: true` | 2,032 us | 2,820 us |
| `Durability.normal` | 483 us | 864 us |
| `keepChanges: false` | 1,816 us | 2,377 us |

The fsync is the write: `Durability.normal` (safe with WAL against
application crashes, may lose the last commits on power loss) is 4.2x
faster at p50. Skipping the change-log row is worth ~11% — one small insert
per commit against a WAL fsync. Both knobs compose (not measured together).

**Gets by id with a bigger cache** — 1,000 random ids read twice in one
process (cold: empty cache; warm: the same ids back), RSS after the runs:

| `cacheSize` | cold | warm | RSS after the runs, − baseline |
|---|---|---|---|
| 2000 (default), 100k | 113 ms | 2 ms | +36 MB |
| 20000, 100k | 115 ms | 2 ms | +37 MB |
| 2000 (default), 300k | 104 ms | 2 ms | +39 MB |
| 20000, 300k | 100 ms | 2 ms | +38 MB |

The explicit RAM/speed trade, in both directions: a warm working set is
~50x faster than SQLite round-trips (113 → 2 ms), and the cache charges RAM
only for documents actually read — 1,000 touched documents fit either
cache, so 20000 costs nothing extra here. `cacheSize` is a *cap*, not a
pre-allocation; it starts costing RAM only when the working set outgrows
2,000 documents, and misses return when it outgrows whatever it is set to.

## Where Cocoon wins

**Indexed reads, by a mile, and the gap grows with the data.** Latest-50 for
one account is 679 us vs 3.7 ms at 10k (5x), 669 us vs 64 ms at 100k (96x),
704 us vs 215 ms at 300k (305x). Cocoon's p50 is *flat* while the dataset
grows 30x — the composite index `(accountId, bookedOn DESC)` serves a keyset
range scan. sembast's store has no index; every `find` with a filter and a
sort order scans the whole store, so its time grows linearly (3.7 → 64 →
215 ms for 10k → 100k → 300k). The measured scaling *is* the evidence: sembast's
query time multiplied ~58x for 30x the data.

**Cold open.** sembast parses its whole log file into RAM on open: 186 ms →
862 ms → 2.36 s. Cocoon opens the SQLite file and reads nothing until asked:
80 → 82 → 82 ms, engine-side open flat at ~78 ms — the dataset-free harness
shows it does not grow with the data at all (the first run's 108 → 229 →
510 ms was the harness building its dataset, not Cocoon). At 300k that is
29x faster to first answer.

**Memory at scale: the engine's own footprint is flat.** With the harness
floor subtracted (baseline: RSS 276 MB, peak 359 MB — a bare `dart run` of
the CLI, nothing opened), Cocoon right after open measures 263 MB at every
size — 12-13 MB *below* the floor, i.e. indistinguishable from it — and
+36/+39/+39 MB after the read ops at 10k/100k/300k. Nothing in the engine
grows with the dataset: the LRU cache holds at most `cacheSize` (2000)
decoded documents, SQLite's per-connection page cache is capped by its
default `cache_size`, and the sqlite_async reader isolates are a fixed
pool. sembast, by contrast, parses every record into RAM at open: +20 →
+200 → +598 MB over the floor for 10k → 100k → 300k, ~2 KB per transaction,
and +704 MB after reads at 300k. Peak RSS is a noisier signal — the
baseline process's own JIT-compile transient peaks at ~359 MB, so both
engines' read peaks land at or under it at 10k, and the honest growth
signal is the after-reads RSS, where sembast climbs to +704 MB and Cocoon
stays at +39 MB.

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
trade working as designed — the cache knob shows both sides of it: a warm
working set of 1,000 ids drops from 113 ms cold to 2 ms warm (50x), and
raising `cacheSize` to 20,000 buys nothing for that working set and costs
no extra RSS (see "The two knobs") because the cache only charges for
documents actually read. At defaults it is still a real loss on cold ids.

**Single writes: 5-7x slower at defaults.** p50 2.1-2.4 ms vs 0.29-0.41 ms
at every size. Why: Cocoon's default `Durability.full` is `PRAGMA
synchronous = FULL` — every commit fsyncs the WAL, so nothing is lost on
power loss. sembast's io factory appends the record to its log and never
fsyncs per record, so it trades durability for speed by default. Cocoon's
`Durability.normal` closes most of the gap by choice, not by default:
2,032 → 483 us at p50 at 100k (4.2x, see "The two knobs") while staying
safe against application crashes; `keepChanges: false` is worth ~11% when
nothing reads the change log.

## Anything that looks wrong

- The bare-harness baseline peaks at ~359 MB (its JIT-compile transient),
  above Cocoon's steady-state read footprint — so "peak − baseline peak"
  lands slightly negative at 10k/100k. Peak RSS is the noisier memory
  signal; the after-reads RSS is the one that tracks the engines.
- Cocoon's single-write p95 grows from 2.8 ms (100k) to 4.3 ms (300k): the
  two index B-trees get deeper and the change log longer. Not an anomaly,
  worth watching on low-end flash.
- sembast's gets non-monotonic across sizes (9 → 46 → 114 ms) tracks its
  in-memory store growing; nothing anomalous.

## Reproduce

```sh
cd packages/cocoon_bench
tool/run_all.sh                 # 10k + 100k + 300k, ~20 min
tool/run_all.sh 10000           # one size
tool/rerun_memory.sh            # baseline + open/rss + the two knobs only
```

Raw numbers: `results/<size>_<engine>_<op>.json` (3 runs each), knob runs
carry their setting in the JSON (`durability`, `keepChanges`, `cacheSize`),
the harness floor in `results/baseline.json`, machine info in
`results/env.json`. Correctness before speed: `dart test` runs a smoke test
that imports a 500-txn dataset into both engines, asserts identical
latest-50 ids and identical monthly totals, and checks the dataset-free
sampling and write-back paths the memory measurements rely on.
