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
/// ascending order. [fields] are wire-level rewrites of changed fields;
/// [backfills] set newly added required fields on every existing document.
final class CocoonMigration {
  /// Builds a step; generated code lists one per migration file.
  const CocoonMigration({
    required this.version,
    this.fields = const [],
    this.backfills = const [],
  });

  /// The schema version this step upgrades the database to.
  final int version;

  /// The field rewrites to apply, in a stable order.
  final List<FieldMigration> fields;

  /// The document backfills to apply after [fields]: one per newly added
  /// field that old documents must gain a value for. Every stub of one
  /// version receives the same decoded document — the document as this
  /// version's [fields] rewrites left it.
  final List<BackfillMigration<Object?>> backfills;

  @override
  String toString() =>
      'CocoonMigration(v$version: '
      '${[...fields, ...backfills].map((f) => f.toString()).join(', ')})';
}

/// One document backfill inside a [CocoonMigration]: every existing document
/// of [model] is decoded and [backfill] decides what [fieldName] should read.
///
/// This is the generated companion of the migrate command's "write a
/// backfill stub" answer: an added field that is non-nullable and has no
/// constructor default would otherwise silently decode to its proto3 zero
/// value (`''`, `0`, `false`, the epoch, the first enum value) in every
/// document written before the field existed. The stub receives the decoded
/// old document — the new field reads its zero value on it — and returns the
/// value to store, so it can depend on the document's other fields.
///
/// [T] is the model class; the returned value must have [fieldType]'s Dart
/// type (`DateTime` fields take a UTC-normalizable [DateTime], enum fields
/// the enum value — stored by name). The engine writes the returned value at
/// [fieldNumber] in the canonical wire document, in batches, inside the open
/// transaction: one change-log row per rewritten document, progress through
/// `onMigrationProgress`, and a throwing stub rolls the whole open back.
///
/// Backfills target storable scalars (`int`, `double`, `bool`, `String`,
/// `DateTime`, `Uint8List`, enums); lists, maps and embedded classes read
/// empty containers and zero instances, which never need a decision.
final class BackfillMigration<T> {
  /// Builds a backfill; generated code lists one per added required field.
  const BackfillMigration({
    required this.model,
    required this.fieldName,
    required this.fieldNumber,
    required this.fieldType,
    required this.wire,
    required this.backfill,
  });

  /// The model class name, e.g. `Txn`. Determines the migrated table.
  final String model;

  /// The field the backfill sets, e.g. `currency`.
  final String fieldName;

  /// The field's number in the lock (fresh — the field was just added).
  final int fieldNumber;

  /// The field's canonical lock type, e.g. `String` or `DateTime`.
  final String fieldType;

  /// The wire encoding [fieldNumber]'s values are stored with.
  final MigrationWireType wire;

  /// Receives the decoded document and returns the value [fieldName] should
  /// read from it on. Returning `null` fails the migration (the field is
  /// non-nullable); throwing aborts the whole open, like a conversion stub.
  final Object? Function(T doc) backfill;

  /// Applies [backfill] to a decoded document, keeping the engine's
  /// `Object?` view type-checked against [T].
  Object? apply(Object? doc) => backfill(doc! as T);

  @override
  String toString() => '$model.$fieldName: $fieldType (#$fieldNumber) backfill';
}

/// One field rewrite inside a [CocoonMigration]: the stored values of field
/// [fromNumber] move to field [toNumber], each transformed by [convert].
///
/// [fromType] and [toType] are the lock's canonical type names (`String`,
/// `int`, `List<String>`, `Map<String,int>`, ...), kept for review and error
/// messages; [fromWire] and [toWire] are the exact wire encodings the two
/// sides read and write — [MigrationWireType.map] for map fields, with the
/// entry encodings in [fromMap] and [toMap]. The generated code builds
/// scalar rewrites through [FieldMigration.typed] so the conversion function
/// stays type-checked; map rewrites are built directly with a convert
/// function that casts the decoded `Map<Object?, Object?>` to the old
/// field's map type first.
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
    this.fromMap,
    this.toMap,
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
  ///
  /// Scalar rewrites only: a map field's decoded value is a
  /// `Map<Object?, Object?>`, which cannot be cast to a typed map argument —
  /// build map rewrites with the [FieldMigration] constructor directly and
  /// cast inside [convert].
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
    MapWireType? fromMap,
    MapWireType? toMap,
    required T Function(S value) convert,
  }) => FieldMigration(
    model: model,
    fromName: fromName,
    fromNumber: fromNumber,
    fromType: fromType,
    fromWire: fromWire,
    fromMap: fromMap,
    toName: toName,
    toNumber: toNumber,
    toType: toType,
    toWire: toWire,
    toMap: toMap,
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

  /// For a map field ([fromWire] is [MigrationWireType.map]): the wire
  /// encodings of the old entries' keys and values. `null` otherwise.
  final MapWireType? fromMap;

  /// For a map field ([toWire] is [MigrationWireType.map]): the wire
  /// encodings of the new entries' keys and values. `null` otherwise.
  final MapWireType? toMap;

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
