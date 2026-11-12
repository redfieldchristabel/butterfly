import 'dart:typed_data';

import 'package:cocoon/cocoon.dart';

part 'models.cocoon.dart';

/// A lat/lon pair, stored inline inside [Address].
@Embedded()
class GeoPoint {
  const GeoPoint({required this.lat, required this.lon});

  final double lat;
  final double lon;
}

/// A postal address, stored inline inside [Account].
@Embedded()
class Address {
  const Address({
    required this.city,
    required this.postCode,
    this.line2,
    this.geo,
  });

  final String city;
  final String postCode;
  final String? line2;
  final GeoPoint? geo;
}

/// The posting state of a transaction, stored by name.
enum TxnStatus { pending, posted, failed }

/// A bank account, rooted at `accounts`.
///
/// The one-field index stays in `indexes:` — the shared-list form; see [Txn]
/// for the stacked `@Index` form composites lead with.
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
    this.tags = const [],
    this.address,
    this.avatar,
  });

  final String name;
  final DateTime openedAt;
  final int balanceMinor; // minor units; may be negative
  final bool active;
  final List<String> tags;
  final Address? address;
  final Uint8List? avatar;
}

/// A transaction of one account, at `accounts/{accountId}/txns`.
///
/// Composites stack as `@Index` lines above the class, in index order.
@Collection('accounts/{accountId}/txns')
@Index(['accountId', '-bookedOn'])
@Index(['status', 'bookedOn'])
class Txn {
  const Txn({
    required this.bookedOn, // yyyymmdd
    required this.amountMinor, // minor units; may be negative
    required this.currency,
    required this.status,
    required this.createdAt,
    required this.rate,
    this.memo,
    this.labels = const [],
    this.meta = const {},
    this.receipt,
  });

  final int bookedOn;
  final int amountMinor;
  final String currency;
  final TxnStatus status;
  final DateTime createdAt;
  final double rate;
  final String? memo;
  final List<String> labels;
  final Map<String, String> meta;
  final Uint8List? receipt;
}

/// One split of a transaction, at
/// `accounts/{accountId}/txns/{txnId}/splits`.
///
/// The index includes both path params: a scoped query always filters them,
/// so Cocoon's index rule only serves the query when they are part of the
/// declared index.
@Collection('accounts/{accountId}/txns/{txnId}/splits')
@Index(['accountId', 'txnId', '-shareMinor'])
class Split {
  const Split({required this.label, required this.shareMinor, this.note});

  final String label;
  final int shareMinor;
  final String? note;
}
