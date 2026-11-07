import 'dart:typed_data';

import 'package:cocoon/cocoon.dart';

part 'models.cocoon.dart';

/// The posting state of a benchmark transaction, stored by name.
enum TxnStatus { pending, posted, failed }

/// One split of a benchmark transaction, stored inline.
@Embedded()
class Split {
  const Split({required this.label, required this.shareMinor});

  final String label;
  final int shareMinor;
}

/// A bank account, rooted at `accounts`.
@Collection(
  'accounts',
  indexes: [
    Index(['name']),
  ],
)
class Account {
  const Account({
    required this.name,
    required this.openedAt,
    required this.balanceMinor,
    required this.active,
  });

  final String name;
  final DateTime openedAt;
  final int balanceMinor;
  final bool active;
}

/// A transaction of one account, at `accounts/{accountId}/txns`, shaped like
/// Finance Sync's model: yyyymmdd booking day, minor-unit amount, an enum
/// status, a memo, labels, splits and a small string map.
@Collection(
  'accounts/{accountId}/txns',
  indexes: [
    Index(['accountId', '-bookedOn']),
    Index(['status', 'bookedOn']),
  ],
)
class Txn {
  const Txn({
    required this.bookedOn,
    required this.amountMinor,
    required this.currency,
    required this.status,
    this.memo,
    this.labels = const [],
    this.splits = const [],
    this.meta = const {},
  });

  /// Booking day as `yyyymmdd` over five years.
  final int bookedOn;

  /// Minor units; negative for debits.
  final int amountMinor;
  final String currency;
  final TxnStatus status;
  final String? memo;
  final List<String> labels;
  final List<Split> splits;
  final Map<String, String> meta;
}
