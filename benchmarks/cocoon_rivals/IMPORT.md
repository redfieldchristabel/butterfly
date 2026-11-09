# The Cocoon bulk-import path, measured before and after step 11

Step 10's rivals matrix (`RESULTS.md`) showed Cocoon's biggest loss: bulk
import (ms, 1000 docs per transaction, `Durability.full`): 1,361 at 10k,
7,984 at 100k, 119,056 at 1M — 3x drift at 100k and superlinear at 1M.
This file records the step-11 measurements: where the time goes (the
profile), what SQLite itself can do (the ceiling), what each change bought,
and what was tried and rejected. Everything here comes from
`tool/profile_import.dart` and `tool/knob_probe.dart`:

```sh
cd benchmarks/cocoon_rivals
dart run tool/profile_import.dart --size 100000             # the profile
dart run tool/profile_import.dart --size 100000 --mode ceiling
dart run tool/knob_probe.dart chunks "PRAGMA cache_size = -65536" \
    "PRAGMA temp_store = MEMORY"                            # raw knob ladder
```

The profile mode instruments the executor around the harness's exact import
path (`runTransaction` + `tx.set`, 1000 docs per transaction). The ceiling
mode runs in its own process: the same table + indexes Cocoon creates,
filled with pre-encoded rows via one `executeBatch` per 1000 rows — at
Cocoon's commit granularity (one transaction per 1000 rows) and inside one
transaction (SQLite's own speed, no per-document layer at all). The two
modes never share a process: the retained dataset's GC pressure skews
in-process ceilings at 100k+ rows (measured, see "Ceiling methodology").
The knob probe runs raw `package:sqlite3` (no sqlite_async, no engine) with
rows built per chunk, so it isolates SQLite itself.

Machine: the same box as RESULTS.md (Intel Core Ultra 5 325, 8 cores,
~27 GB RAM, Dart 3.13.7, SQLite 3.54.1). Measurement conditions changed
mid-step: the step's own agent job and test runs share the box, and the
same configuration measured twice in a row can differ by ~25-30% (three
identical raw-probe runs at 1M: 18.7 / 22.0 / 24.1 s). Treat single runs as
±30%; the published engine numbers are medians of 3 fresh harness processes.

## Phase 1: baseline (before any change)

### The profile at 100k (`--size 100000`)

| measurement | value | share |
|---|---|---|
| total import wall | 7,884 ms (78.8 us/doc) | 100% |
| `tx.execute` calls | 100,000 (1/doc, the upserts) | |
| — wait on them | 3,521 ms | 45% |
| `tx.executeBatch` calls | 100,000 (1/doc, the change rows) | |
| — wait on them | 1,578 ms | 20% |
| `adapter.encode` | 137 ms | 1.7% |
| encode→decode normalize round trip | 202 ms | 2.6% |
| SQL string building (per doc) | 86 ms | 1.1% |
| change-row parameter building | 11 ms | 0.1% |
| unaccounted (async/await machinery of 200k round trips, cache staging, refs) | 2,348 ms | 30% |

Every document pays **two isolate round trips** (one `execute` for the
upsert, one `executeBatch` of a single row for its change-log entry) —
200,000 hops for 100k documents. The round trips' wait alone is 65% of the
wall; the event-loop machinery that drives them is most of the rest. The
actual Dart work (encode, normalize, SQL building) is ~5%.

### The profile at 1M (`--size 1000000`)

| measurement | value | share |
|---|---|---|
| total import wall | 118,216 ms (118.2 us/doc) | 100% |
| `tx.execute` wait (upserts) | 43,161 ms | 37% |
| `tx.executeBatch` wait (changes) | 15,255 ms | 13% |
| `adapter.encode` | 1,015 ms | 0.9% |
| encode→decode normalize round trip | 1,792 ms | 1.5% |
| SQL string building | 753 ms | 0.6% |
| change-row parameter building | 78 ms | 0.1% |
| unaccounted | 56,163 ms | 47% |

Same shape, worse: 2,000,000 round trips. The Dart-side costs stay small;
the per-document round trip — and the async machinery around it — is the
import.

### The SQLite ceiling (fresh process, pre-encoded rows, same table + indexes)

| size | one txn per 1000 rows | one txn for all rows |
|---|---|---|
| 10k | 99 ms (9.9 ms/chunk) | 48 ms |
| 100k | 2,597 ms (26.0 ms/chunk) | 921 ms |
| 1M | 84,181 ms (84.2 ms/chunk) | 14,649 ms |

Two findings:

1. **The per-document layer is the 100k loss.** At Cocoon's own commit
   granularity, SQLite does the same rows in 2.6 s at 100k where Cocoon
   spends 7.9 s — the difference is 200k round trips plus their await
   machinery. Batching the same 1000-doc transaction into two
   `executeBatch` calls instead of 2,000 round-trips closes exactly that
   gap.
2. **The 1M curve is per-commit cost, not per-row cost.** At 1M, SQLite
   needs 84 s when the rows land in 1,000 transactions but 14.6 s in a
   single transaction. The ~70 ms/commit difference at 1M (~17 ms at 100k)
   is WAL auto-checkpoint churn and cold B-tree page reads at a database
   size the 2 MB default page cache can no longer hold.

### Ceiling methodology note

The first ceiling attempt ran in the same process as the profile, after the
import. At 100k it read 7,951 ms — 3x the isolated 2,597 ms — because the
retained typed dataset (~100k `Txn` objects) drives GC cycles between
chunks. That is why `--mode ceiling` exists and why the numbers above come
from separate processes (the same fresh-process rule the harness itself
uses). An earlier in-process ceiling also reused one database for both
ceiling variants, making the single-transaction ceiling measure upserts of
already-present rows; the fresh-file version above replaced it.

### Index key order (investigated, no change)

The `path` UNIQUE index keys (`accounts/aXX/txns/tNNNNNNNNN`) are inserted
account-round-robin, so each of the five index B-trees sees ~20 hot subtree
locations, not fully random keys — with a 64 MB page cache the hot top
levels plus the hot leaves stay resident. Reordering the secondary indexes
(or the scope index) does not change the insert cost measurably; the
remaining per-chunk cost at 1M is checkpoint churn (see the rejected knob
above). `WITHOUT ROWID` was considered and rejected: the table's natural
key is the long `path` string, which every secondary index would embed as
its rowid replacement — index bloat, plus a schema/format change for a gain
the knobs already deliver. Not pursued.

## Phase 2: fixes, measured after each change

Baseline row to beat (same box, same conditions): **7,884 ms at 100k,
118,216 ms at 1M** (the profile's own import; RESULTS.md's medians are
7,984 / 123,600 ms).

Changes (a)-(d) landed together — each maps to one measured Phase-1 cost:

- (a) `WriteBatch` (`db.batch()`): queue synchronously, one write
  transaction per commit, same-SQL runs become one `executeBatch`.
- (b) buffered writes inside `runTransaction` (flush at commit, before any
  read or delete, every 2,000 rows) — the profile's path benefits without
  changing its call shape.
- (c) per-collection upsert/update SQL built once at registry time.
- (d) writes cache the document's encoded bytes (`EncodedDoc`), decoded
  lazily on the first cache read — no encode→decode round trip per write.

Measured right after (a)-(d) — with batching in, round trips collapsed
from 200,000 to 200 at 100k, but the wall DID NOT MOVE:

| change | 100k import | 1M import | kept? |
|---|---|---|---|
| baseline (step 10 engine) | 7,884 ms | 118,216 ms | |
| (a)-(d) batched writes | 7,987 ms | not re-run | yes — necessary but not sufficient (see below) |
| (e1) sqlite_async `profileQueries: false` | 2,969 ms | 72,354 ms | yes |
| (e2) `pageCacheMiB` 64 + `tempStoreInMemory` (engine defaults) | 2,893 ms | 72,354 ms | yes (measured jointly with (e1), see the note) |
| (e3) `walAutoCheckpointPages` 8000 (32 MiB) | 2,051 ms | 53,614 ms | yes |

The (a)-(d) row is the finding of the step: 200 round trips instead of
200,000 cut the SQL wait from 5,099 ms to 706 ms while the wall stayed at
~7.9 s and the profile's unaccounted share jumped from 30% to 86% — the
cost had moved, not vanished. Chasing it found sqlite_async's dev-mode
query profiling: with `profileQueries` on (its default outside release
builds), every executed statement builds a `TimelineTask` plus an arguments
map on the database isolate — measured at ~50 us per statement, i.e. ~5 s
of the 100k import and ~44 s of the 1M import, paid inside the round-trip
waits before the change (which is why the baseline profile attributed 65%
of the wall to "waiting on SQLite"). The engine now opens with
`profileQueries: false` (Cocoon's DevTools integration does not read those
events). After that, the profile's shape is honest: at 100k the 200 batched
round trips wait 674 ms, the Dart-side work is ~460 ms, and the remainder
(~0.9 s) is the per-document put loop, cache staging and 100 commits.

(e2) and (e3) are the PRAGMA defaults, isolated through the raw knob probe
at 1M (per-1000-row transactions, rows built per chunk, `synchronous=FULL`,
`journal_size_limit` 6 MB):

| configuration | 1M import | note |
|---|---|---|
| cache 64 MB + temp MEMORY, default checkpoints (1000 pages) | 45.6 s | re-run of Phase 1's 35.6 s config; the box was busier (see the noise note) |
| + `wal_autocheckpoint = 4000` pages (16 MiB) | 22.0 s | |
| + `wal_autocheckpoint = 8000` pages (32 MiB) | 18.7 / 22.0 / 24.1 s (three runs) | **kept as the default**; WAL bounded at 6-36 MB |
| `wal_autocheckpoint = 0` (Phase 1) | rejected | WAL grows to 4.2 GB |

Checkpointing every ~4 MB was the 1M killer: at 1M each 1000-row commit
writes more WAL than the checkpoint threshold, so SQLite checkpointed (and
with a 6 MB `journal_size_limit`, truncated the WAL) after nearly every
commit, at a cost that grows with the database. An 8000-page interval keeps
the WAL bounded (~32 MiB during heavy writes — not the unbounded 4.2 GB of
the rejected setting) and roughly halves the import. Crash safety is
unchanged: the WAL is durable; a larger interval only moves checkpoint work
from every commit to every ~32 MiB (some of it returns as open-time WAL
recovery after a crash).

Per-transaction overhead of sqlite_async itself was measured to rule the
driver out: on a filled 1M database, 1,000 empty `writeTransaction`s cost
0.14 ms each and 1,000 one-row transactions 2.75 ms each (commit + fsync);
the driver adds nothing that matters. What remains between the engine's 1M
(53.6 s) and the raw floor (~19-24 s) is SQLite's own per-commit work under
the measured conditions plus GC pressure from the retained benchmark
dataset — the engine's own layer accounts for ~2.6 s at 1M (engine 53.6 s
vs its same-configuration ceiling before the checkpoint knob landed:
67.6 s was itself GC-skewed, see below).

What was tried and dropped, with the numbers:

- `PRAGMA wal_autocheckpoint = 0`: 22.7 s at 1M in Phase 1, but a 4.2 GB
  WAL — rejected (the bounded 8000-page interval keeps most of the win).
- `WITHOUT ROWID`: rejected on shape grounds (long `path` keys would bloat
  every secondary index; a file-format change), before measuring — see the
  index-key-order note above.
- Renaming the single-write `execute` into a one-row `executeBatch` for
  uniformity: no change measured (both are one round trip); not pursued as
  a separate change.

### Ceiling methodology addendum (step 11)

The `--mode ceiling` process retains all 1M pre-encoded rows (~500 MB of
live byte lists) by design so encoding stays out of the timed section.
That retention skews the ceiling the same way the typed dataset did at
100k+: with the engine's PRAGMA defaults, the ceiling measured 67.6 s at 1M
while the engine itself — same shape, same process isolation, same PRAGMAs
— measured 53.6 s. A low-retention variant (rows built per chunk, one batch
at a time) measured 49.5 s per 1000-row transaction on an already-filled
1M database. The 100k ceiling (2,364 ms) stays clean and is the honest
floor the 100k engine number is read against (2,051 ms engine — the engine
now sits below the pre-step-11 ceiling). The knob probe (rows built per
chunk) is the authoritative SQLite floor at 1M.

## Final (step 11 as committed)

The benchmark harness (`tool/run_all.sh`) re-measured the write-path cells
(`import`, `write`, `rww`, `restore`, `verify`) for `cocoon` and
`cocoon-normal` at all four sizes; the benchmark's cocoon import now uses
`db.batch()` per 1000 rows (the bulk path, mirroring drift's `db.batch`),
and every number below is the median of 3 fresh processes from
`results/*.json`:

| size | import before | import after | drift | `cocoon-normal` after |
|---|---|---|---|---|
| 10k | 1,361 ms | 225 ms | 258 ms | 183 ms |
| 100k | 7,984 ms | 2,075 ms | 2,692 ms | 1,867 ms |
| 300k | 32.0 s | 12.3 s | 15.1 s | 8.8 s |
| 1M | 119.1 s | 64.7 s | 95.5 s | 58.7 s |

Also from this run: single writes at `Durability.full` 2,978 -> 1,787 us p50 at
1M (drift 2,918), the 300k NDJSON restore 33.0 -> 11.2 s (drift 13.9 s), and
`tool/check_verify.py` still passes for every engine at every size.

After review (Brain): the page cache and in-memory temp store apply to the
**write connection only**; readers keep SQLite's defaults, so several pooled
readers don't each hold 64 MiB on a phone, and reads behave exactly as they
were measured in step 10. The read-while-write cells were re-run with that
(p95 3.0 ms at 1M). `PRAGMA journal_size_limit = 4 MiB` truncates an idle WAL
file back after a checkpoint, so the larger checkpoint interval doesn't leave
32 MiB of WAL on disk.

Still open: the raw SQLite ceiling is 19-24 s at 1M, so the document layer
costs roughly 40 s over plain SQLite at that size. The profile points at the
remaining per-document Dart work and the index-table rows; that is the next
place to look.

**Correction (step 12):** that 19-24 s floor came from the knob probe's
synthetic rows, whose booking days all fell inside one 28-day window, so the
indexes filled nearly in order. `CEILING.md` re-measures the floor with the
real value shape and Cocoon's real DDL: 70.9 s at 1000 rows per commit. Cocoon
is already at the ceiling for that commit pattern; the remaining lever is the
commit pattern itself (indexes built after a bulk load: 9.5 s).

## Step 13: the BulkWriter, measured onto the ceiling

The engine got a real bulk-load path: `db.bulkWriter()` (Firestore's
BulkWriter shape) — queue `set`/`update`/`delete` synchronously, commit every
`chunkSize` rows as one write transaction, atomic per chunk, never as a
whole — plus deferred secondary indexes (drop the touched tables' secondary
indexes during the load, rebuild them at `close()`, crash recovery via the
`_cocoon_bulk` meta table). `tool/profile_import.dart --mode bulk` measures
the real writer over the benchmark dataset; `bin/bench.dart --op bulkimport`
measures it in the harness's fresh-process shape against each engine's best
documented bulk API (drift one batch, Isar one `writeTxn` + `putAll`,
ObjectBox one `putMany`, Hive one `putAll`, sembast one transaction — the
1000-per-commit `import` row is kept as the like-for-like comparison).

Conditions: the same box as every table above, but with other agents' jobs
running alongside (`dart` VMs were active all afternoon), so single runs
carry the ±30% documented at the top; every configuration below is one fresh
process, `Durability.full`, the shipped default PRAGMAs, and every run
verified its row count against the dataset.

### The chunk-size curve at 1M (deferIndexes on, 1,000,000 rows, fresh database)

| chunkSize (rows/commit) | wall s | CPU s | peak RSS MB | file MB | peak WAL MB |
|---|---|---|---|---|---|
| 1,000 | 17.9 | 17.0 | 1,354 | 375.4 | 112.1 |
| **10,000 (default)** | **13.3** | 14.8 | 1,422 | 375.5 | 123.9 |
| 50,000 | 14.0 | 16.1 | 1,498 | 374.5 | 131.6 |
| 100,000 | 14.6 | 16.9 | 1,491 | 375.4 | 102.2 |
| 1,000,000 (everything) | 17.6 | 20.2 | 1,693 | 377.5 | 278.0 |

The curve is a shallow U with its knee at 10k — that is the default. Two
findings: the WAL stays bounded but grows with the chunk (10k chunks peak at
~124 MB; "everything" at 278 MB — `wal_autocheckpoint` 8000 pages only moves
32 MiB per checkpoint and `journal_size_limit` 4 MiB still shrinks the file
after a checkpoint, so the peak is transient); and a single 1M-row chunk is
*slower* than 10k chunks — the one write transaction stages 1M hot-cache
updates and a 1M-entry touched set in the engine (peak RSS +270 MB) on top
of SQLite's own work.

### The levers at 1M

| configuration | wall s | what it says |
|---|---|---|
| chunk 1,000, deferIndexes off | 73.9 | the writer at the old per-1000 commit pattern sits at CEILING v1's raw floor (70.9 s) — sanity anchor |
| chunk 10,000, deferIndexes off | 36.7 | big chunks alone halve the per-1000-commit cost |
| chunk 10,000, deferIndexes on (default) | 13.3 / 14.3 | deferred indexes are the big lever, as CEILING v4 said |
| chunk 10,000, deferIndexes on, path sort on | 13.3 / 14.3 | sorting each chunk by document path |
| chunk 10,000, deferIndexes on, path sort off | 12.7 / 12.4 | plain call order — *faster* |

**Path order was measured and kept out.** At the engine's 10k-row chunk
granularity with 20 round-robin accounts, sorting each chunk by `path` cost
~1 s (the sort) and bought no locality the raw v5 probe saw at 1M-row runs;
the writer commits in call order. The delete-vs-write ordering hazard a sort
would have introduced (an ancestor delete must not float above a later
descendant write) goes away with it.

### The deferral cross-over on a pre-filled 1M table (chunk 10,000)

The writer defers a table's indexes only when it pays: when the table is
empty, or when the writer has buffered more rows for the table than the
table already holds. Measured against that rule (`--prefill 1000000`, the
timed phase adds rows to the 1M table):

| add (rows) | rule decision | deferIndexes on | deferIndexes off |
|---|---|---|---|
| 100k | keeps indexes (100k ≤ 1M) | 3.5 s | 4.0 s |
| 300k | keeps indexes | 10.9 s | 20.3 s |
| 1M | keeps indexes (1M ≤ 1M, not >) | 48.6 s | 59.9 s |
| 1.1M | **defers** (1.1M > 1M) | **22.9 s** | 66.4 s |

Below the rule's threshold both columns behave identically (no deferral
either way), so their spread is the box's noise — the load cost is the same
whether the flag is set, which is the point: the rule's decision is invisible
there. Above it the pair is the honest A/B: at +1.1M rows the deferred load
(22.9 s, including rebuilding the four secondary indexes over the full 2.1M
rows) is 2.9x faster than maintaining them through every chunk (66.4 s). The
measured cross-over sits right where the rule draws it; a load that at least
doubles the table wants deferral, a load that adds less keeps the indexes.

### The harness row

`bin/bench.dart --engine cocoon --size 1000000 --op bulkimport` (queue-all
then close, defaults): **wall 14,374 ms, CPU 15,710 ms, peak RSS 1,689 MB,
file 524 MB with sidecars** (the WAL was still up when the size was taken;
the database file alone is 375 MB as in the profile runs). The buffer holds
every queued operation until its chunk commits — that is the RSS; an app
loading faster than it commits bounds the memory with `flush()`. The
verify-after-bulkimport contract check (bulkimport, then the read shapes,
every engine, 500 txns) is in `test/smoke_test.dart` and passes.

What the writer does NOT change: `db.batch()`, transactions, reads, watches,
the change log, cache coherence, migrations and crash safety are untouched —
`packages/cocoon`'s full suite (251 tests) passes with 23 new BulkWriter
tests, and the rivals' `import` op still measures the 1000-per-commit path
exactly as before.
