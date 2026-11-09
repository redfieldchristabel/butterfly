/// The ObjectBox side of the benchmark: one flat `ObTxn` entity with `@Index`
/// on accountId, bookedOn and status, the way the ObjectBox docs model this
/// data (labels/splits/meta as JSON text columns; ObjectBox has no list or
/// map property types). The string ids of the dataset are not valid
/// ObjectBox ids (ObjectBox ids are ints), so `code` stores the stable id
/// under a unique index and the numeric ObjectBox id is assigned FROM the
/// string id (its digits + 1) — that keeps get-by-id a native primary-key
/// lookup and every internal-id ordering in the string id's order.
library;

import 'package:objectbox/objectbox.dart';

/// The numeric ObjectBox id of a stable string id (`t000123456` → 123457,
/// `w…` writer ids → 2e9 + seq). Monotonic in the string id.
int obIntIdOf(String id) {
  final digits = int.parse(id.substring(1));
  return id.startsWith('w') ? 2000000000 + digits : digits + 1;
}

/// One transaction of one account, in a flat ObjectBox box.
@Entity()
class ObTxn {
  /// The ObjectBox id, assigned from the stable string id (see
  /// [obIntIdOf]).
  @Id(assignable: true)
  int id = 0;

  /// The stable benchmark id, e.g. `t000000000`, under a unique value index.
  @Unique()
  @Index(type: IndexType.value)
  late String code;

  /// The parent account id, e.g. `a07`.
  @Index()
  late String accountId;

  /// Booking day as `yyyymmdd`.
  @Index()
  late int bookedOn;

  /// Minor units; negative for debits. Its own index serves the amount
  /// workloads (top debits, amount bands) the way a documented ObjectBox
  /// app declares it.
  @Index()
  int amountMinor = 0;

  /// The ISO 4217 code.
  late String currency;

  /// The posting state, stored by name under its own index.
  @Index()
  late String status;

  /// Free text, absent as null.
  String? memo;

  /// The labels as a JSON array.
  late String labelsJson;

  /// The splits as a JSON array of `{label, shareMinor}`.
  late String splitsJson;

  /// The meta map as a JSON object.
  late String metaJson;
}
