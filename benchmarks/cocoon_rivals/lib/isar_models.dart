/// The Isar (isar_community) side of the benchmark: one flat `IsarTxn`
/// collection with an `accountId` property — Isar has no subcollections —
/// the composite index `(accountId, bookedOn)` and a `status` index, the way
/// the Isar docs model this data. The string ids of the dataset are not
/// valid Isar ids (Isar ids are ints), so `code` stores the stable id under
/// a unique value index and the numeric Isar id is assigned FROM the string
/// id (its digits + 1), which keeps every ordering the numeric id decides in
/// the string id's order — the tie-break the shared read contracts need.
///
/// Isar has no `Map` field type: `meta` is stored as its JSON text, the
/// community docs' workaround for small maps.
library;

import 'package:cocoon_rivals/models.dart' show TxnStatus;
import 'package:isar_community/isar.dart';

part 'isar_models.g.dart';

/// The numeric Isar id of a stable string id (`t000123456` → 123457, `w…`
/// writer ids → 2e9 + seq). Monotonic in the string id, so index walks and
/// Dart sorts over the internal id agree with the shared contracts.
int isarIntIdOf(String id) {
  final digits = int.parse(id.substring(1));
  return id.startsWith('w') ? 2000000000 + digits : digits + 1;
}

/// One split of a benchmark transaction, stored as an embedded object.
@embedded
class IsarSplit {
  /// The split label.
  late String label;

  /// The share in minor units.
  late int shareMinor;
}

/// One transaction of one account, in a flat Isar collection.
@collection
class IsarTxn {
  /// The Isar id, assigned from the stable string id (see [isarIntIdOf]).
  Id id = Isar.autoIncrement;

  /// The stable benchmark id, e.g. `t000000000`, under a unique index —
  /// this is how an Isar app keys records by a string id.
  @Index(unique: true, type: IndexType.value)
  late String code;

  /// The parent account id; the composite index serves one account's
  /// day-ordered reads.
  @Index(composite: [CompositeIndex('bookedOn')])
  late String accountId;

  /// Booking day as `yyyymmdd`.
  late int bookedOn;

  /// Minor units; negative for debits.
  late int amountMinor;

  /// The ISO 4217 code.
  late String currency;

  /// The posting state, stored as an Isar enum (byte) with its own index.
  @enumerated
  @Index()
  late TxnStatus status;

  /// Free text, absent as null.
  String? memo;

  /// The labels.
  late List<String> labels;

  /// The splits.
  late List<IsarSplit> splits;

  /// The meta map, Isar's JSON-text workaround (Isar has no Map fields).
  late String metaJson;
}
