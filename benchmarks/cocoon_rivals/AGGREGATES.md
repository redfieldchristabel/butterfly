# Aggregates: before/after (step 17)

`db.bulkWriter()`'s deferred-index work made the bulk *loads* fast; this
step moves the *math* into SQLite. `monthlyTotals`, `yearReport` and the
counts in `lib/cocoon_engine.dart` now run through Cocoon's aggregates —
`query.groupBy([bucket(Txn$.bookedOn, width: 100)]).aggregate([sum(...)])`
instead of paging every matching document and summing in Dart. Everything
else (indexes, dataset, durability, harness, methodology) is unchanged
from the v2 rivals run; the numbers are the harness's usual median of 3
fresh `dart run` processes.

**Noise note:** the Android emulator was running on the box for both the
before and after measurements tonight, so treat every number below as
±30% (the standing rivals-methodology caveat) — the gaps are far larger
than the noise except where marked.

## The table (1,000,000 txns, `cocoon-normal` = `Durability.normal`)

| Workload | before (paged, Dart sums) | after (aggregates) | drift v2 (SQL) | after vs drift |
|---|---|---|---|---|
| Monthly totals, one account, one year | 185 ms · 9,874 documents read | **35 ms · 12 group rows** | 104 ms (sums in Dart) | not like-for-like (see below) |
| Year report, all 20 accounts | 1,430 ms | **376 ms** | 358 ms | 1.05x — at parity within noise |
| Count `pending` across all accounts (p50) | 3,534 us | 3,554 us | 2,407 us | unchanged (already a SQL count) |
| Count one account's year (p50) | 566 us | 640 us | 314 us | unchanged (already a SQL count) |

Raw runs: `results/step17/{before,after}_1000000_cocoon-normal_{monthly,
yearreport,count}.json` (v2 baseline files remain untouched in
`results/`). Grand totals and per-month sums are byte-identical before and
after (909,925,638 for the monthly op, 19,855,411,567 across the year
report), and the full `verify` dump — every read shape's contract output —
diffed against drift's stored dump with `tool/check_verify.py` still
matches after the switch.

## What changed per workload

- **Monthly totals**: was ~740 pages of 500 documents (one document decode
  each) plus a Dart accumulator; now ONE statement —
  `SELECT (f_booked_on - (((f_booked_on % ?) + ?) % ?)) AS k0,
  COALESCE(SUM(f_amount_minor), 0) AS a0, count(*) AS c FROM txn
  WHERE p_account_id = ? AND f_booked_on BETWEEN ... GROUP BY k0
  ORDER BY k0 ASC` — twelve rows, zero decodes. 5.3x faster than
  Cocoon's own before. Not a like-for-like with drift's 104 ms: the drift
  engine's monthly workload still reads the rows and sums in Dart (only
  its year report uses SQL `GROUP BY`), so drift would be about as fast
  here if it pushed the sum down too. The fair SQL-vs-SQL comparison is
  the year report below.
- **Year report**: was the same paged shape, per account, ×20 (200k
  document reads at 1M); now 20 groupBy statements (one per account —
  `paramKey` over a collection group would make it one statement, but
  p_account_id grouping is what the per-account contract returns, and the
  step's benchmark shape keeps one call per account). 3.8x faster than
  Cocoon's before; the 3.6x gap to drift's `GROUP BY` is closed (376 vs
  358 ms, inside the noise band).
- **Counts**: `count()` was already `SELECT count(*)` through the same
  planner; the step made it sugar for `aggregate([count()])` — the emitted
  SQL is the same statement, and the p50 deltas (±6%) are noise, not a
  change.

## What's left of the gap, and why

- **Counts vs drift (2,407 us vs ~3,500 us pending, p50)**: drift executes
  through one raw SQLite connection; Cocoon pays sqlite_async's isolate
  hop on the same statement. That
  is the standing single-statement overhead, not an aggregate cost.
- **Single-statement latency generally**: the aggregate `get()` shares the
  query path's executor round trip (~0.5-0.7 ms floor on this box), so
  sub-millisecond workloads don't benefit from pushdown — the wins start
  where row counts dominate.
- **One call per account in the year report**: grouping a collection group
  by the parent param (`paramKey`) is supported and tested, but the
  benchmark contract returns per-account maps anyway; folding the 20 calls
  into one `paramKey` statement would remove ~19 index seeks (~nothing at
  35-376 ms scale) and is left as the app's choice, not the benchmark's.
- **Firestore parity note**: `sum` of a nullable/double field and
  `average` follow Firestore semantics (empty sum = 0, average always
  `double?`), so Cocoon's aggregates match the cloud API you'd port from —
  drift's SQL has no such contract to match.

Verdict: the last big structural loss in RESULTS.md ("no aggregate
pushdown") is gone. The year report is now at parity with drift's own SQL
GROUP BY, and monthly totals are 5.3x faster than before; the remaining Cocoon-vs-drift losses are the
standing ones (file size, bulk import vs in-RAM engines, per-statement
latency), not the report workloads.
