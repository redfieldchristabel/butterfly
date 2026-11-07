/// On-device schema migrations: the typed step list an app hands to
/// `Cocoon.open`, and the error for a database newer than the app.
///
/// The `cocoon_generator:migrate` CLI writes one [CocoonMigration] per schema
/// version into `lib/cocoon_migrations/` and collects them in a
/// `cocoonMigrations` list; the app passes that list (with the lock's
/// `cocoonSchemaVersion`) to [Cocoon.open], which applies every pending step
/// once, in order, inside one transaction.
library;

import 'wire.dart';

/// One schema migration step: rewrites the stored documents of a collection
/// from the field layout of an older schema version to the current one.
///
/// [version] is the lock version this step brings the database up to; the
/// engine runs every step whose [version] is greater than the stored one, in
/// ascending order.
final class CocoonMigration {
  /// Builds a step; generated code lists one per migration file.
  const CocoonMigration({required this.version, required this.fields});

  /// The schema version this step upgrades the database to.
  final int version;

  /// The field rewrites to apply, in a stable order.
  final List<FieldMigration> fields;

  @override
  String toString() =>
      'CocoonMigration(v$version: ${fields.map((f) => f.toString()).join(', ')})';
}

/// One field rewrite inside a [CocoonMigration]: the stored values of field
/// [fromNumber] move to field [toNumber], each transformed by [convert].
///
/// [fromType] and [toType] are the lock's canonical type names (`String`,
/// `int`, `List<String>`, ...), kept for review and error messages;
/// [fromWire] and [toWire] are the exact wire encodings the two sides read
/// and write. The generated code builds these through [FieldMigration.typed]
/// so the conversion function stays type-checked.
final class FieldMigration {
  /// Builds a rewrite with an untyped [convert].
  const FieldMigration({
    required this.model,
    required this.fromName,
    required this.fromNumber,
    required this.fromType,
    required this.fromWire,
    required this.toName,
    required this.toNumber,
    required this.toType,
    required this.toWire,
    required this.convert,
  });

  /// Builds a rewrite whose [convert] takes and returns the field's real
  /// Dart types instead of `Object?`, so the generated migration list is
  /// type-checked against the conversion functions it calls.
  ///
  /// [S] is the old field's Dart type as stored (a `String` field yields
  /// `String`; `int` and `DateTime` fields yield `int`, their microseconds
  /// representation; enums yield `String`, their name) and [T] the new
  /// field's. Values are never null: documents without the old field are
  /// skipped entirely, before [convert] runs.
  static FieldMigration typed<S, T>({
    required String model,
    required String fromName,
    required int fromNumber,
    required String fromType,
    required MigrationWireType fromWire,
    required String toName,
    required int toNumber,
    required String toType,
    required MigrationWireType toWire,
    required T Function(S value) convert,
  }) => FieldMigration(
    model: model,
    fromName: fromName,
    fromNumber: fromNumber,
    fromType: fromType,
    fromWire: fromWire,
    toName: toName,
    toNumber: toNumber,
    toType: toType,
    toWire: toWire,
    convert: (Object? value) => convert(value as S),
  );

  /// The model class name, e.g. `Txn`. Determines the migrated table.
  final String model;

  /// The old field's name, e.g. `currency` (for review and messages).
  final String fromName;

  /// The old field number, reserved in the lock after the migration.
  final int fromNumber;

  /// The old field's canonical lock type, e.g. `String`.
  final String fromType;

  /// The wire encoding the old values were stored with.
  final MigrationWireType fromWire;

  /// The new field's name, e.g. `currencyCode`.
  final String toName;

  /// The new field number, fresh in the lock.
  final int toNumber;

  /// The new field's canonical lock type, e.g. `int`.
  final String toType;

  /// The wire encoding the converted values are stored with.
  final MigrationWireType toWire;

  /// Converts one stored value. Sees only documents whose old field was
  /// present, always with a non-null value; returning `null` drops the
  /// value. Throwing aborts the whole migration (the open rolls back).
  final Object? Function(Object? value) convert;

  @override
  String toString() =>
      '$model.$fromName: $fromType (#$fromNumber) -> '
      '$toName: $toType (#$toNumber)';
}

/// Thrown by `Cocoon.open` when the database on disk was written by a NEWER
/// schema version than the running app declares.
///
/// Opening would silently misread data written under unknown field numbers,
/// so the app must be upgraded (or the version argument corrected) instead.
final class SchemaTooNewException implements Exception {
  /// Builds the error from the database's and the app's versions.
  SchemaTooNewException(this.storedVersion, this.appVersion);

  /// The schema version stored in the database file.
  final int storedVersion;

  /// The schema version the app passed to `Cocoon.open`.
  final int appVersion;

  @override
  String toString() =>
      'SchemaTooNewException: the database was written by schema version '
      '$storedVersion, but this app declares $appVersion; upgrade the app '
      'before opening it.';
}
