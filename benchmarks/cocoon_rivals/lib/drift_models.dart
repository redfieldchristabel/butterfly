/// The drift side of the benchmark: plain tables with the columns a finance
/// app would declare — the transaction fields directly, labels/splits/meta
/// as JSON text columns — and the indexes of the step: `(account_id,
/// booked_on DESC)` and `(status, booked_on)`, plus a bare `(booked_on)` for
/// the all-accounts range. Opened with `NativeDatabase.createInBackground`,
/// the same isolate shape as Cocoon: this engine is the SQLite speed limit
/// the document layer is measured against.
library;

import 'package:drift/drift.dart';

part 'drift_models.g.dart';

/// One transaction row of the `txn_rows` table.
class TxnRows extends Table {
  /// The stable benchmark id, e.g. `t000000000`.
  TextColumn get id => text()();

  /// The parent account id, e.g. `a07`.
  TextColumn get accountId => text()();

  /// Booking day as `yyyymmdd`.
  IntColumn get bookedOn => integer()();

  /// Minor units; negative for debits.
  IntColumn get amountMinor => integer()();

  /// The ISO 4217 code.
  TextColumn get currency => text()();

  /// The posting state, stored by name.
  TextColumn get status => text()();

  /// Free text, absent as SQL NULL.
  TextColumn get memo => text().nullable()();

  /// The labels as a JSON array.
  TextColumn get labelsJson => text()();

  /// The splits as a JSON array of `{label, shareMinor}`.
  TextColumn get splitsJson => text()();

  /// The meta map as a JSON object.
  TextColumn get metaJson => text()();

  @override
  Set<Column> get primaryKey => {id};
}

/// The drift database: one file per engine directory, background isolate.
@DriftDatabase(tables: [TxnRows])
class AppDb extends _$AppDb {
  /// Builds the database over [db] — the engine passes
  /// `NativeDatabase.createInBackground(file)`.
  AppDb(super.db);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      // The step's index set, written exactly as specified — drift's
      // @TableIndex cannot express the descending part.
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_txn_account_booked '
        'ON txn_rows (account_id, booked_on DESC)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_txn_status_booked '
        'ON txn_rows (status, booked_on)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_txn_booked ON txn_rows (booked_on)',
      );
    },
  );
}
