# Where the bytes go: Cocoon's storage at 1M transactions

> **Shipped layout (step 20):** Cocoon ships the L2 layout measured below —
> no stored `path` column, identity = scope key — with the change log kept
> and prunable. See [Shipped layout](#shipped-layout-step-20) for the
> re-measured numbers; everything above stays as the history of how the
> decision was made.

Measurements, not guesses, of where Cocoon's 1M bytes go and what each layout
change would buy. Two dev tools produced them (not shipped, no engine changes):

- `tool/storage_anatomy.dart` — opens a checkpointed **copy** of the real
  1M databases the rivals matrix built
  (`/tmp/cocoon_rivals_run/cocoon_rivals_cocoon_1000000/cocoon.db`,
  `.../cocoon_rivals_drift_1000000/drift.db`; the originals are never opened
  for writing) and reads the `dbstat` virtual table (bundled SQLite 3.54.1
  has it). MB below are MiB (1024²), matching `RESULTS.md` and `CEILING.md`.
- `tool/storage_probe.dart` — loads 1M rows into fresh databases, one layout
  variant each, from the ceiling probe's row generator (`chunkRows`: real
  DDL read from a small engine-built `cocoon.db`, blobs of the real encoded
  size, the dataset's value shape), at Cocoon's writer pragmas, secondary
  indexes built after the load (Cocoon's measured bulk path). Medians of 3
  fresh-process runs.

## Shipped layout (step 20)

Cocoon shipped the **L2 layout**: the stored `path` column and its UNIQUE
autoindex are gone; a document is its scope key (`p_account_id`, `id`,
unique through `cx_txn_scope`), and the full path is derived from it. The
change log stays (L2, not L4) because it is prunable at runtime —
`pruneChanges` / `changeRetention` get the L4 bytes back whenever an app
wants them, with no layout change.

Re-measured with the same probe (`tool/storage_probe.dart`, variants
renumbered: L0 = shipped, L1 = no change log, L2 = WITHOUT ROWID reference,
L3 = drift reference) after the engine change — the real DDL the probe reads
from a fresh engine-built database IS the new layout:

| variant | what | file MB | saving vs old L0 MB | load s | index s | get p50 µs | latest-50 p50 µs | monthly groupBy p50 µs | delete p50 µs |
|---|---|---|---|---|---|---|---|---|---|
| L0 | shipped layout: scope-key identity + change log per doc (no path column) | 304.9 | 69.8 | 5.5 | 3.7 | 10 | 61 | 109,078 | 23 |
| L1 | L0 without change-log rows (the pruning ceiling) | 252.7 | 121.9 | 4.7 | 3.6 | 9 | 55 | 106,335 | 23 |

Per-object medians (MB):

| object | type | L0 MB | L1 MB |
|---|---|---|---|
| txn | table | 126.3 | 126.3 |
| _cocoon_changes | table | 52.2 | 0.0 |
| cx_txn_31eb54e047d080dd | index | 29.9 | 29.9 |
| cx_txn_54b66501d86f96a9 | index | 26.8 | 26.8 |
| cx_txn_scope | index | 24.7 | 24.7 |
| cx_txn_f4ecd63f00d4b439 | index | 23.0 | 23.0 |
| cx_txn_4081929ae6be2a63 | index | 22.0 | 22.0 |

Sanity: L0's file (304.9 MB) and every per-object number match the step-14
L2 probe to the decimal — the shipped layout is exactly the variant the
step-14 measurements predicted, including the table payload's drop from
154.9 to 125.1 B/row (the stored `path` was ~28 B) and the disappearance of
`sqlite_autoindex_txn_1` (39.4 MB). The monthly groupBy is new in this
table: one account's whole 50k-row history bucketed into months by
`bucket(bookedOn, width: 100)` (the engine's exact integer SQL: count and
sum per `yyyymm00`), statement time, no range filter — the filtered
month-report numbers live in `AGGREGATES.md`. Engine-level runs
(`tool/shipped_layout_measure.dart`, the real Cocoon API at 1M,
`Durability.full`):

| measurement | result |
|---|---|
| `bulkWriter()` 1M import (fresh file, indexes deferred) | 11.9 s (was ~13 s on the old layout) |
| fresh file after import (20 accounts + 1M txns + change log) | 322,551,808 B (307.6 MiB) |
| get by id p50 | 380 µs (engine round trip incl. cache) |
| latest-50 p50 | 643 µs |
| monthly groupBy, whole account history (50k rows) | 73 ms |
| single delete p50 (delete + re-add untimed) | 1.76 ms |
| subtree delete: one account + its 50,000 txns | 1.16 s, 50,001 change rows |
| file after the subtree delete | 322,789,376 B |

The old-format migration, measured on a scratch copy of the real 1M
pre-step-20 file (`/tmp/cocoon_rivals_run/cocoon_rivals_cocoon_1000000/
cocoon.db`, 409,088,000 B — the exact file Part A anatomized):

- the first open rebuilds both collection tables inside the open: **5.1-8.7 s**
  across two runs on the shared box (the table rebuild + every index
  recreated), reporting progress per table;
- the data and log survive intact: 1,000,025 documents and the change log
  head #1,000,690 — both exactly the file's pre-migration values from
  Part A; the second open does no work (3 ms);
- the migrated file is transiently **larger** (544,337,920 B; the dropped
  old tables' pages sit on the freelist — 214.2 MB) until a compaction
  reclaims them: `VACUUM` takes 4.3 s and lands at **319,778,816 B —
  304.9 MiB, byte-for-byte the probe's L0 size**. `db.backupTo()` performs
  the same compaction as part of every backup.

Noise note: measured 2026-11-10 on the shared build box through Foreman
(no emulator running); single runs, medians of 3 for the probe variants.

## Part A: anatomy of the real files

Both files were closed cleanly by their engines: **no WAL sidecar existed
before the checkpoint** (the checkpoint on the copy is a no-op), freelist 0
pages, `auto_vacuum` off. Post-import benchmark ops explain the row counts:
the change log holds 1,000,690 rows (1M import + 690 later writes), the txn
table 1,000,025 rows (665 of those writes were updates, 25 new documents).

### cocoon.db — 390.1 MiB (99,875 pages × 4096 B)

| object | type | pages | MB | % of file | entries | avg payload B |
|---|---|---|---|---|---|---|
| txn | table | 40486 | 158.1 | 40.5 | 1,000,025 | 154.9 |
| _cocoon_changes | table | 13372 | 52.2 | 13.4 | 1,000,690 | 48.0 |
| sqlite_autoindex_txn_1 (`path UNIQUE`) | index | 10090 | 39.4 | 10.1 | 1,000,025 | 34.0 |
| cx_txn_31eb54e047d080dd (`status, bookedOn, id`) | index | 8876 | 34.7 | 8.9 | 1,000,025 | 28.1 |
| cx_txn_54b66501d86f96a9 (`accountId, -bookedOn, id`) | index | 7582 | 29.6 | 7.6 | 1,000,025 | 25.0 |
| cx_txn_f4ecd63f00d4b439 (`bookedOn, id`) | index | 6918 | 27.0 | 6.9 | 1,000,025 | 21.0 |
| cx_txn_scope (`accountId, id` UNIQUE) | index | 6336 | 24.8 | 6.3 | 1,000,025 | 20.0 |
| cx_txn_4081929ae6be2a63 (`amountMinor, id`) | index | 6207 | 24.2 | 6.2 | 1,000,025 | 19.9 |
| account + indexes, _cocoon_meta, sequence, schema | — | 8 | 0.1 | 0.0 | — | — |
| **total** | | 99875 | **390.1** | 100.0 | | |

Content averages: `data` blob **92.0 B**, `path` **28.0 B**, `id` **10.0 B**,
`p_account_id` **3.0 B**; the `f_` columns' record encoding sums to
**~14 B/row** (bookedOn ~3.5 varint, status text ~7.5, amountMinor ~3.5;
the rest of the 154.9 B payload is the ~8 B record header). Change-log rows
average **48.0 B** payload (path 28, tbl 3, op 3, at ~6, seq header ~8).

### drift.db — 236.8 MiB (60,621 pages × 4096 B)

| object | type | pages | MB | % of file | entries | avg payload B |
|---|---|---|---|---|---|---|
| txn_rows | table | 38604 | 150.8 | 63.7 | 1,000,022 | 147.6 |
| idx_txn_status_booked (`status, booked_on`) | index | 5452 | 21.3 | 9.0 | 1,000,022 | 17.1 |
| sqlite_autoindex_txn_rows_1 (`id` PK) | index | 5290 | 20.7 | 8.7 | 1,000,022 | 16.0 |
| idx_txn_account_booked (`account_id, booked_on DESC`) | index | 4566 | 17.8 | 7.5 | 1,000,022 | 14.0 |
| idx_txn_booked (`booked_on`) | index | 3494 | 13.6 | 5.8 | 1,000,022 | 10.0 |
| idx_txn_amount (`amount_minor`) | index | 3214 | 12.6 | 5.3 | 1,000,022 | 8.9 |
| schema | — | 1 | 0.00 | 0.0 | 6 | 130.7 |
| **total** | | 60621 | **236.8** | 100.0 | | |

Content averages: id 10.0, account_id 3.0, booked_on/amount_minor stored as
integers, currency 3.0, status 6.1, memo 9.9 B (40% NULL), labels_json 13.5,
splits_json 60.0, meta_json 27.5 → **147.6 B/row**. Drift stores every field
once, as columns; there is no blob and no change log.

### What the anatomy says

- **The 153.3 MB gap to drift decomposes exactly**: change log 52.2 + the
  path column inside the table ~30 + the `path UNIQUE` autoindex 39.4 +
  secondary indexes 115.5 vs drift's 85.9 (+29.6) + the scope index vs
  drift's id PK (+4.1) + the txn table's own edge (+7.3) = 153.3 MB.
- **The blob is NOT the problem**: Cocoon's 154.9 B row is *smaller* than
  drift's 147.6 B row once you subtract Cocoon's path (28) — the protobuf
  blob (92 B) encodes labels/splits/meta more compactly than drift's JSON
  text columns (60 B for splits_json alone).
- **Indexed fields are stored twice, and it is small**: the `f_` columns
  duplicate ~14 B/row that also sit inside the 92 B blob — **~14 MB of the
  156.6 MB table at 1M**. The rest of the blob (currency, memo, labels,
  splits, meta) has no columnar twin.
- **Index-entry shape**: every Cocoon secondary index appends the 10 B
  document id (keyset pagination's tiebreaker) where drift's entries carry
  only the implicit 4 B rowid — ~6 B/entry × 4 indexes ≈ **23 MB**. The
  `path UNIQUE` autoindex is the single biggest index (34 B/entry).
- **Fill factor**: the real file's secondary indexes hold the same payload
  bytes per entry as the probe's rebuilds but ~15% more pages (e.g. 34.7 vs
  29.9 MB for the status index): they were maintained live through 1M
  random-order inserts, the probe's are built by a sorted `CREATE INDEX`.
  This matches `CEILING.md` (v1 336 MB with live indexes vs v4 322 MB with
  deferred ones): deferred builds save ~15 MB of fill, not just time. The
  probe's L0 below is therefore the *bulk-path steady state*; the real file
  is ~15 MB fatter.

## Part B: layout variants at 1M

Method: the exact DDL from a small engine-built `cocoon.db` (`readRealSchema`
in `tool/ceiling_probe.dart`, reused), rows from that probe's `chunkRows`
(blobs of exactly the real 91 B average), one fresh database per variant per
run, per-1000-row commits in dataset order, `synchronous = FULL`, Cocoon's
writer pragmas; the scope index / primary key stays live (it is the write
path's conflict target), the four secondary indexes are built after the load
in every variant. L5 reads its DDL from the real `drift.db` and generates
drift-shaped rows (all fields as columns, labels/splits/meta as JSON) with
the same distributions and seeding.

Reads (p50 over 200 runs on a warm process, statement time only — the
commit's fsync is identical for every layout): **get** = one document by its
full identity (`path = ?` for L0/L1, `p_account_id = ? AND id = ?` for
L2-L4, the drift `id` PK for L5); **latest-50** = one account's newest 50 by
`bookedOn DESC`; **delete** = one document with its subtree, expressed the
way the layout allows — a path range `path >= p AND path < p0` (the engine's
half-open descendants range) for L0/L1, the scope/PK key for L2-L5. The txn
table is **flat — there are no child collections — so every subtree is the
row itself**; the re-insert that undoes each delete (and the change-log row
a real delete would append) is untimed.

| variant | what | file MB | saving vs L0 MB | load s | index s | get p50 µs | latest-50 p50 µs | delete p50 µs |
|---|---|---|---|---|---|---|---|---|
| L0 | Cocoon DDL as-is: path UNIQUE + change log per doc (today) | 374.7 | — | 6.9 | 3.5 | 6 | 60 | 28 |
| L1 | L0 without change-log rows | 322.5 | 52.2 | 7.1 | 3.6 | 6 | 59 | 28 |
| L2 | no path column/UNIQUE; scope (p_account_id, id) unique | 304.9 | 69.7 | 5.4 | 3.4 | 7 | 58 | 20 |
| L3 | L2 as WITHOUT ROWID, PRIMARY KEY (p_account_id, id) | 286.7 | 88.0 | 10.0 | 3.2 | 7 | 76 | 20 |
| L4 | L2 + L1: no path, no change log | 252.7 | 121.9 | 4.6 | 3.3 | 7 | 56 | 21 |
| L5 | drift's layout for the same data (reference) | 230.9 | 143.8 | 5.7 | 3.1 | 6 | 79 | 21 |

Per-object medians (MB):

| object | type | L0 MB | L1 MB | L2 MB | L3 MB | L4 MB | L5 MB |
|---|---|---|---|---|---|---|---|
| txn | table | 156.6 | 156.6 | 126.3 | 136.4 | 126.3 | — |
| _cocoon_changes | table | 52.2 | 0.0 | 52.2 | 52.2 | 0.0 | — |
| sqlite_autoindex_txn_1 | index | 39.4 | 39.4 | — | — | — | — |
| cx_txn_31eb54e047d080dd | index | 29.9 | 29.9 | 29.9 | 29.9 | 29.9 | — |
| cx_txn_54b66501d86f96a9 | index | 26.8 | 26.8 | 26.8 | 23.0 | 26.8 | — |
| cx_txn_scope | index | 24.7 | 24.7 | 24.7 | — | 24.7 | — |
| cx_txn_f4ecd63f00d4b439 | index | 23.0 | 23.0 | 23.0 | 23.0 | 23.0 | — |
| cx_txn_4081929ae6be2a63 | index | 22.0 | 22.0 | 22.0 | 22.1 | 22.0 | — |
| txn_rows (drift) | table | — | — | — | — | — | 150.8 |
| sqlite_autoindex_txn_rows_1 (drift `id` PK) | index | — | — | — | — | — | 20.7 |
| idx_txn_status_booked | index | — | — | — | — | — | 19.2 |
| idx_txn_account_booked | index | — | — | — | — | — | 16.3 |
| idx_txn_booked | index | — | — | — | — | — | 12.4 |
| idx_txn_amount | index | — | — | — | — | — | 11.4 |

Sanity: the probe reproduces each real layout's content — L0's per-object
payload averages match Part A to the decimal (28.1 = 28.1, 25.0 = 25.0, …),
L5's txn_rows is 150.8 MB exactly like the real one. The probe files are
slightly smaller than the real ones (374.7 vs 390.1; 230.9 vs 236.8) because
their indexes are sorted-rebuild (100% fill) instead of live-maintained, and
the real files carry the account table, `_cocoon_meta` and the post-import
writes. The *deltas* between variants are layout-true.

### What the variants say

- **L1 — the change log alone is 52.2 MB** (13.9% of today's file), exactly
  its Part A bytes. Load time does not move (the log is an append-only
  rowid table written in the same commit).
- **L2 — dropping `path` and its UNIQUE index saves 69.7 MB**: the
  autoindex (39.4) plus the path column inside every row (30.3). No read
  gets slower: get +1 µs (noise), latest-50 identical, **delete is faster**
  (20 vs 28 µs — a scope-key point delete beats a path-range delete).
- **L3 — WITHOUT ROWID saves 18.2 MB more** but costs real performance:
  load 10.0 s vs 5.4 s (random-order inserts into the clustered TEXT key —
  page splits; the rowid table just appends) and latest-50 +31% (76 vs
  58 µs; its secondary entries can't carry the 4 B rowid — the measured
  index sizes confirm the swap: the accountId index shrinks 26.8 → 23.0 MB
  because the rowid disappears, the others stay flat because the appended
  `p_account_id` replaces it).
- **L4 — both changes together: 121.9 MB, a third of the file**, with every
  measured read as fast or faster than L0, and the fastest load of all
  (4.6 s — no change-log rows to append).
- **L5 — drift's layout is 143.8 MB below L0, but only 21.8 MB below L4.**
  The remainder is drift's narrower secondary indexes (no appended 10 B id)
  partially offset by its fatter rows (147.6 vs 125.1 B payload — Cocoon's
  protobuf blob beats drift's JSON columns).

## Hypotheses, verdicts

1. **"The `path` TEXT column + its UNIQUE index are redundant" — CONFIRMED
   as 69.7 MB at 1M (18.6% of the file).** Each collection has its own
   table and `(p_account_id, id)` already identifies a document; the
   measured reads do not regress without it. What actually needs `path`
   today: single-range subtree deletes on collections with children, the
   inspector's path display, and `ON CONFLICT(path)`.
2. **"One change-log row per written document costs ~50 MB at 1M" —
   CONFIRMED: 52.2 MB** (48 B/row payload; CEILING v1→v2's 52 MB file delta
   was this exact table). The log is already prunable at runtime, so the
   saving is reachable without a layout change.
3. **"Indexed fields are stored twice (blob + `f_` columns)" — CONFIRMED
   but small: ~14 MB at 1M (~3.6% of the file).** The f_ columns are the
   query path and cannot go without a parseable blob; the blob itself is
   the canonical wire format (watch dedup by byte equality, journal-chain
   hashing, wire-level migrations) and is *more* compact than drift's
   columnar encoding of the same fields.

## Ranked list

Measurements first; the "cost" column is analysis, and the last column
separates measured facts from design opinion.

| # | layout change | saving at 1M | measured read/write effect | what Cocoon would have to re-do differently |
|---|---|---|---|---|
| 1 | Drop `path` + its UNIQUE index (L2) | **69.7 MB** | get +1 µs, latest-50 ±0, **delete faster** (20 vs 28 µs); load 1.5 s faster (fewer bytes + one index less to build) | Subtree deletes: no single `path >= ? AND path < ?` range scan — collections **with** children delete per child table by key (this flat table: one point delete, measured). Inspector path display rebuilds from `p_` params. Migration: SQLite 3.54 refuses `DROP COLUMN` on a UNIQUE column (its autoindex cannot be dropped either — verified on this engine), so removing `path` is a table rebuild in the migration runner; the table shape hash changes, so every existing file rewrites once. Collection-group queries, cursors: unaffected (`p_` columns and index plans stay). Upsert conflict target moves to the scope index (same cost class). *Opinion: the cheapest large saving; the migration is the real work.* |
| 2 | Stop keeping one change-log row per document (L1), or prune it (no layout change) | **52.2 MB** | reads unchanged; load unchanged | Watches do not read the log (commit events are in-memory), but a sync outbox / audit trail and `watchFrom(cursor)` anchoring do — per-document granularity would need a per-batch watermark design, not just a delete. Pruning to a retention window gets the same bytes back today with zero layout change. *Opinion: prune first, re-layout only if an outbox actually ships.* |
| 3 | Both of the above (L4) | **121.9 MB (32% of the file)** | every read ≤ L0, fastest load (4.6 s) | Sum of 1 and 2. |
| 4 | WITHOUT ROWID, PK = scope (L3) | +18.2 MB on top of L2 | **load 2× slower** (10.0 vs 5.4 s), latest-50 +31%, delete/get unchanged | The scope index disappears into the table (saves 24.7 MB) but the clustered TEXT key inserts randomly — the +10.1 MB table and the load regression both come from that; a path-ordered bulk load might claw it back (unmeasured). Clustered order also changes scan locality for collection-group queries. Migrations: same table-rebuild cost as #1, plus `WITHOUT ROWID` tables cannot later add a rowid. *Opinion: measured rejection at this dataset shape.* |
| 5 | Drift's exact shape (L5) | 143.8 MB vs L0, but only 21.8 MB vs L4 | latest-50 slower than L2 (79 vs 58 µs — no trailing id in its indexes), everything else equal | Give up the canonical blob (watch dedup by byte equality, journal hashing, wire-level migrations) and the per-collection change log; rows get *fatter* (JSON > protobuf). Not a layout tweak — a different database. |

Noise note: Part B ran while an unrelated Finance Sync build job (Foreman F-0072) shared the box, so load seconds and read microseconds carry extra noise; file and object sizes are deterministic and unaffected.

Not measured, deliberately:

- **Subtree delete with children** — the benchmark table is flat, so the
  path-range vs per-child-table delete difference (the real cost of #1 for
  collections that have subcollections) does not appear; only the single-row
  shapes were timed.
- **L3 with a path-ordered (cluster-friendly) load** — would need a sorted
  input the engine does not promise.
- **fsync/commit costs** — excluded from the read p50s (in-transaction
  statement timing); identical for every layout by construction.
- **The account table, `_cocoon_meta`, multi-collection files** — negligible
  in Part A (< 0.1 MB at 20 accounts).

## Reproduce

```sh
# Part A (copies the real dbs into the scratch dir, checkpoints the copies)
dart run tool/storage_anatomy.dart

# Part B (18 runs at 1M, ~7 min total; --out files feed --collect)
dart run tool/storage_probe.dart --variant L0 --run 1 \
    --out /tmp/cocoon_step14_scratch/probe_runs/L0_1.json   # ...per run
dart run tool/storage_probe.dart --collect /tmp/cocoon_step14_scratch/probe_runs

# smoke at 20k first:
dart run tool/storage_probe.dart --variant L0 --size 20000

# Step 20's shipped-layout section (engine level + the old-format migration
# and the freelist/VACUUM reclaim; both copy the real 1M file, never write it):
dart run tool/shipped_layout_measure.dart
dart run tool/vacuum_probe.dart
```

Android emulator off; originals under `/tmp/cocoon_rivals_run` untouched
(opened read-only, and only their file sizes and sidecar names were read);
copies and probe databases lived under `/tmp/cocoon_step14_scratch` and were
deleted after. `RESULTS.md` and `results/` untouched.
