# The SQLite ceiling map at 1M transactions

What is the fastest SQLite itself can load Cocoon's real `txn` table, and what
does each lever buy? `tool/ceiling_probe.dart` (dev tool, not shipped) answers
with raw `package:sqlite3` calls, no document layer:

- the **exact** DDL Cocoon creates, read from a real `cocoon.db`'s
  `sqlite_master` (table `txn`, the scope index, 4 secondary indexes including
  the step-12 amount index, the change-log table);
- row blobs of the real encoded size (91 bytes on average) and the dataset's
  value shape: 20 accounts, booking days over five years, random amounts, the
  85/10/5 status mix;
- rows built per 1000-row chunk (low retention, see the step-11 ceiling
  addendum in `IMPORT.md`);
- Cocoon's writer pragmas: 64 MiB page cache, `temp_store = MEMORY`,
  `wal_autocheckpoint = 8000`, `journal_size_limit = 4 MiB`,
  `synchronous = FULL` unless the variant says otherwise.

Every variant is a fresh database; numbers are medians of 3 fresh-process runs.

| variant | what | wall s | load s | index build s | peak RSS MB | CPU s | file MB |
|---|---|---|---|---|---|---|---|
| v1 | per-1000 commits, all indexes live, dataset order | 70.9 | 70.8 | - | 344 | 34.4 | 336 |
| v2 | v1 + one change-log row per document (Cocoon today) | 76.8 | 76.7 | - | 343 | 36.0 | 388 |
| v2b | v1 + one change-log row per 1000-doc batch | 72.6 | 72.5 | - | 339 | 34.5 | 336 |
| v3 | all rows in ONE transaction | 10.9 | 10.8 | - | 340 | 10.6 | 336 |
| v4 | secondary indexes built after the load | 9.5 | 6.2 | 3.4 | 400 | 7.4 | 322 |
| v5 | v4, rows inserted in `path` order | 7.6 | 4.6 | 3.0 | 404 | 5.8 | 324 |
| v6 | integer rowid key, `path` unique + secondaries at the end | 8.6 | 4.8 | 3.7 | 414 | 6.7 | 319 |
| v7 | v1 through sqlite_async `executeBatch` | 79.2 | 79.2 | - | 355 | 36.2 | 336 |
| v8a | v1 with `synchronous = NORMAL` | 73.1 | 73.0 | - | 343 | 36.3 | 336 |
| v8b | v4 with `synchronous = NORMAL` | 7.4 | 4.1 | 3.2 | 401 | 6.9 | 322 |

For reference: Cocoon's own 1M import (step 11, three secondary indexes, before
the amount index) is 64.7 s at `Durability.full` and 58.7 s at `normal`; Hive
8.0 s, ObjectBox 18.0 s, Isar 24.9 s.

Disk written is not in the table: this WSL2 kernel has no per-process io
accounting (`/proc/self/io` does not exist). The benchmark harness falls back
to the process's cgroup `io.stat` where one is reachable (see `OpCost`); on
this box neither is, so `env` reports `diskWriteSource: none` and the disk
columns stay empty rather than showing a made-up zero.

## What the map says

**1. The step-11 "raw floor" of 19-24 s was optimistic.** It came from
`tool/knob_probe.dart`, whose synthetic rows put every booking day inside one
28-day window and had no amount index, so the secondary indexes filled almost
in order. With the real value shape and four secondary indexes, SQLite at
Cocoon's commit pattern (1000 rows per commit) takes **70.9 s**. A control run
of the step-11 knob probe on the same box the same afternoon still measures
20.8 s, so the difference is the row shape, not the machine. Cocoon's own
import is therefore already *at* the ceiling for its commit pattern; the
document layer is not where the time goes.

**2. The cost is per commit, not per row.** The same rows in one transaction
take 10.9 s (6.5x faster). `synchronous = NORMAL` barely moves v1 (73.1 s), so
it is not fsync: each 1000-row commit dirties pages scattered across four
random-order index B-trees, and that page volume goes through the WAL and the
checkpoint again and again. Fewer commits, or no index maintenance during the
load, removes it.

**3. Building the indexes after the load is the big lever.** v4 loads in
6.2 s and builds the four indexes in 3.4 s: 9.5 s total, 7.5x faster than v1
and already ahead of ObjectBox. Inserting in `path` order (v5) gets 7.6 s;
with `synchronous = NORMAL` (v8b) 7.4 s, Hive's territory.

**4. Smaller levers.** One change-log row per document costs 5.9 s over v1;
one per batch costs 1.7 s. The sqlite_async isolate hop costs 8.3 s (12%) over
direct calls. An integer rowid key buys ~1 s over v5 at the price of a
file-format change; not worth it.

## Levers for step 13, ranked

| lever | est. saving at 1M | what it costs |
|---|---|---|
| Bulk-load mode: secondary indexes built after the load | ~60 s | queries on those indexes during the load must wait or scan; a crash mid-load needs a marker so open rebuilds the indexes; only worth it for big loads (restore, first sync, import) |
| Larger commits on the bulk path (fewer, bigger transactions) | up to ~60 s | the writer lock is held longer, the WAL grows with the transaction (needs a bound), coarser crash/progress points; sizes between 1000 and "everything" are unmeasured |
| Insert in key order where the caller allows it | ~2 s on top of the above | only when the input can be sorted cheaply |
| One change-log row per batch | ~5 s | changes what watchers and sync consumers read; needs a design, not just a speed-up |
| Direct FFI writer (no isolate hop) | ~8 s | must not block the app's isolate: a dedicated writer isolate, more code to own |
| Integer rowid key | ~1 s | file-format change; skip |

Fairness note for the benchmark: the rivals' imports also commit every 1000
rows. If Cocoon gains a bulk-load path, the benchmark must say so and give each
rival its own best documented bulk API (Hive `putAll`, Isar one `writeTxn`,
ObjectBox `putMany`, drift one `batch`) in a separate "best bulk path" row,
keeping the 1000-per-commit row as is.

Reproduce: `dart run tool/ceiling_probe.dart --size 1000000 --runs 3`
(Android emulator off; about 25 minutes).
