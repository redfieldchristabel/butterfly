// GENERATED CODE - DO NOT MODIFY BY HAND, except the conversion bodies.
//
// Cocoon schema migration to version 2, written by
// `dart run cocoon_generator:migrate`. Implement every
// `upgrade...` function below, then run build_runner again: the build
// fails while any `UnimplementedError` remains.

// Txn.bookedOn: String (#1) -> bookedOn: int (#10)

import 'package:cocoon/cocoon.dart';

/// Converts Txn.bookedOn (String, #1)
/// to bookedOn (int, #10).
int upgradeTxnBookedOn(String old) => int.parse(old.replaceAll('-', ''));

/// The field rewrites of this migration, listed by 'migrations.dart'.
final m0002Migrations = <FieldMigration>[
  FieldMigration.typed<String, int>(
    model: 'Txn',
    fromName: 'bookedOn',
    fromNumber: 1,
    fromType: 'String',
    fromWire: MigrationWireType.text,
    toName: 'bookedOn',
    toNumber: 10,
    toType: 'int',
    toWire: MigrationWireType.sint64,
    convert: upgradeTxnBookedOn,
  ),
];
