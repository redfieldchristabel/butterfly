# `db.getAll(refs)`: many documents by id in one trip (step 22)

The rivals bench's `gets` workload loads 1,000 random ids one `doc.get()` at
a time — 92 ms at 1M, one isolate round trip plus one decode per document.
Apps that load a set of known ids (a split's participants, linked accounts,
a sync batch) pay that per document. This step adds
`db.getAll(refs)` (and `tx.getAll(refs)`, `collection.getAll(ids)`): results
in refs order, `null` where a document is missing, duplicates allowed,
cache-first, misses fetched per table in chunks of 500 scope keys inside ONE
read transaction.

Numbers below come from `tool/getall_measure.dart` (a separate tool; the
existing `gets` workload and its results files are untouched), on the same
1M rivals databases (`cocoon-normal`, drift), 5 in-process reps per shape
with a fresh Cocoon instance per rep, medians reported. The ids are the
`gets` sample: the harness's seeded reservoir (`Random(424242)`) over the
dataset's deterministic ids, streamed in Cocoon's table order — the two 1M
databases carry 22 extra `w`-id rows left by the read-while-write op, and
the sample's universe excludes them so it stays reproducible against any
fresh import; every measured id is checked to exist before a number is
reported.

**Noise note:** WSL2 desktop box, other agent jobs idle; the first rep of
each shape pays a cold OS page cache and lands 3-6x high (visible in the
raw runs), which the median discards. Treat gaps under ~20% as noise.

## The table (1,000,000 txns, medians of 5)

| ids | `get()` one-by-one (today) | `getAll` cold | `getAll` warm | drift `isIn` (1 statement) | drift chunked at 500 |
|---|---|---|---|---|---|
| 50 | 13.7 ms | **2.8 ms** | **0.03 ms** | 1.5 ms | 1.4 ms |
| 1,000 | 75.0 ms | **8.7 ms** | **0.20 ms** | 9.6 ms | 12.0 ms |
| 10,000 | 409 ms | **93 ms** | 77 ms (see cache note) | 64 ms | 77 ms |

Verdict: at 1,000 ids `getAll` is **~8.6x faster than the one-by-one gets
it replaces** (8.7 ms vs 75 ms; the rivals table's fresh-process `gets`
median, 92 ms, sits in the same band), and at parity or better with drift's
single `isIn` statement (8.7 vs 9.6 ms) — drift pays for materialising full
row objects where Cocoon decodes wire blobs into the model. Warm repeats are
cache hits: ~0.2 ms for 1,000 documents, no SQL at all.

At 10,000 ids `getAll` (93 ms) beats the one-by-one path 4.4x but trails
drift's single statement (64 ms): 23 round trips (21 chunked SELECTs +
BEGIN + END) at ~2 ms per hop add up, and the hot-document cache holds only
2,000 documents (`CocoonOptions.cacheSize`), so a second call re-reads
~8,000 of them — that is the "warm" number above, honestly not warm.
Batching beyond the cache size wins the round trips but not the decode or
the row transport; nothing to fix, it is what a bounded cache means.

## Where the remaining time goes (1,000 ids, cold 8.7 ms)

| piece | ms | what it is |
|---|---|---|
| round trips + SQL | 5.7 | the same chunked statements `getAll` runs, executed on a raw connection: a read-transaction BEGIN + 2 chunk SELECTs + END over sqlite_async's reader isolate — ~1.4 ms per hop, the isolate round trip dominating the ~0.1 ms of actual SQLite work |
| decode | 0.9 | 1,000 wire blobs through the generated adapter (`WireReader`) |
| engine Dart work | ~2.1 | refs -> scope keys, row -> path derivation, snapshots, list assembly |

So the floor is the isolate round trips, not SQLite: the same statements
run in ~0.1 ms of raw SQL, and the chunk-size sweep says the statement
itself stops mattering past ~500-1,000 keys per chunk —

| chunk (keys per statement) | 1,000 ids, sql-only median |
|---|---|
| 50 | 12.4 ms (21 statements) |
| 100 | 7.1 ms |
| 250 | 5.8 ms |
| **500 (shipped)** | **5.2 ms** |
| 1,000 | 4.7 ms |
| 2,000 | 4.7 ms |
| 4,000 | 4.6 ms |

500 keys per statement is within ~10% of the floor while keeping each
statement a small, single index scan and the per-chunk blob memory bounded;
that is the shipped `getAllChunkKeys`.

## Methodology

- `dart run tool/getall_measure.dart --size 1000000 --count {50,1000,10000}`
  (Cocoon), `--engine drift` (drift), and `--chunk-sweep` (the sweep above).
- Cocoon reps: fresh `Cocoon.open` per rep — `getAll` cold is the first
  document read on an empty cache, `getAll` warm is the second call on the
  same instance; the one-by-one number runs on a separate fresh instance as
  the first read, replicating the harness's `gets` op exactly
  (`CocoonBenchEngine.getsById`'s shape).
- sql-only / one-statement / decode floors run on a raw `SqliteDatabase`
  probe connection: identical statements, rows discarded (decode floor:
  rows fetched untimed, then 1,000 `WireReader` decodes timed).
- drift: `SELECT * FROM txn_rows WHERE id IN (...)` through drift's select
  API — one statement for all ids, and chunked at 500 for the same
  statement count as `getAll`.
- No results/*.json written; the rivals harness and its committed numbers
  are untouched.
