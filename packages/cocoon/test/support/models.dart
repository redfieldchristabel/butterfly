import 'dart:typed_data';

import 'package:cocoon/cocoon.dart';

/// Test models and hand-written adapters, written exactly the way the code
/// generator will emit them: typed column handles, an `IndexDef` per
/// `@Collection(indexes: [...])` entry, and canonical `WireWriter` codecs
/// with ascending field numbers.

enum TxnStatus { pending, posted, failed }

class Account {
  const Account({required this.name, required this.active, this.note});

  final String name;
  final bool active;
  final String? note;

  Account copyWith({String? name, bool? active, String? note}) => Account(
    name: name ?? this.name,
    active: active ?? this.active,
    note: note ?? this.note,
  );

  @override
  bool operator ==(Object other) =>
      other is Account &&
      other.name == name &&
      other.active == active &&
      other.note == note;

  @override
  int get hashCode => Object.hash(name, active, note);

  @override
  String toString() => 'Account($name, $active, $note)';
}

class Txn {
  const Txn({
    required this.bookedOn,
    required this.amountMinor,
    required this.rate,
    required this.currency,
    required this.status,
    required this.createdAt,
    this.memo,
  });

  final int bookedOn; // yyyymmdd, so sort keys tie often
  final int amountMinor; // may be negative
  final double rate;
  final String currency;
  final TxnStatus status;
  final DateTime createdAt;
  final String? memo;

  Txn copyWith({
    int? bookedOn,
    int? amountMinor,
    double? rate,
    String? currency,
    TxnStatus? status,
    DateTime? createdAt,
    String? memo,
  }) => Txn(
    bookedOn: bookedOn ?? this.bookedOn,
    amountMinor: amountMinor ?? this.amountMinor,
    rate: rate ?? this.rate,
    currency: currency ?? this.currency,
    status: status ?? this.status,
    createdAt: createdAt ?? this.createdAt,
    memo: memo ?? this.memo,
  );

  @override
  bool operator ==(Object other) =>
      other is Txn &&
      other.bookedOn == bookedOn &&
      other.amountMinor == amountMinor &&
      other.rate == rate &&
      other.currency == currency &&
      other.status == status &&
      other.createdAt.microsecondsSinceEpoch ==
          createdAt.microsecondsSinceEpoch &&
      other.memo == memo;

  @override
  int get hashCode => Object.hash(
    bookedOn,
    amountMinor,
    rate,
    currency,
    status,
    createdAt.microsecondsSinceEpoch,
    memo,
  );

  @override
  String toString() => 'Txn($bookedOn, $amountMinor, $currency, $status)';
}

class Split {
  const Split({required this.label, required this.shareMinor});

  final String label;
  final int shareMinor;

  @override
  bool operator ==(Object other) =>
      other is Split && other.label == label && other.shareMinor == shareMinor;

  @override
  int get hashCode => Object.hash(label, shareMinor);

  @override
  String toString() => 'Split($label, $shareMinor)';
}

// -- Column handles (generated per model) -----------------------------------

final accountName = FieldColumn.text<Account, String>(
  'name',
  read: (a) => a.name,
);
final accountActive = FieldColumn.boolean<Account, bool>(
  'active',
  read: (a) => a.active,
);
final accountNote = FieldColumn.text<Account, String?>(
  'note',
  read: (a) => a.note,
  nullable: true,
);

final txnBookedOn = FieldColumn.integer<Txn, int>(
  'bookedOn',
  read: (t) => t.bookedOn,
);
final txnAmountMinor = FieldColumn.integer<Txn, int>(
  'amountMinor',
  read: (t) => t.amountMinor,
);
final txnRate = FieldColumn.real<Txn, double>('rate', read: (t) => t.rate);
final txnCurrency = FieldColumn.text<Txn, String>(
  'currency',
  read: (t) => t.currency,
);
final txnStatus = FieldColumn.enumerated<Txn, TxnStatus>(
  'status',
  read: (t) => t.status,
  values: TxnStatus.values,
);
final txnCreatedAt = FieldColumn.dateTime<Txn, DateTime>(
  'createdAt',
  read: (t) => t.createdAt,
);
final txnMemo = FieldColumn.text<Txn, String?>(
  'memo',
  read: (t) => t.memo,
  nullable: true,
);

final splitLabel = FieldColumn.text<Split, String>(
  'label',
  read: (s) => s.label,
);
final splitShareMinor = FieldColumn.integer<Split, int>(
  'shareMinor',
  read: (s) => s.shareMinor,
);

// -- Adapters ----------------------------------------------------------------

final class AccountAdapter extends CollectionAdapter<Account> {
  AccountAdapter();

  @override
  String get model => 'Account';

  @override
  final pattern = CollectionPattern.parse('accounts');

  @override
  List<FieldColumn<Account, Object?>> get columns => [
    accountName,
    accountActive,
    accountNote,
  ];

  @override
  List<IndexDef> get indexes => [
    IndexDef.fromFields(['name']),
  ];

  @override
  Uint8List encode(Account value) {
    final writer = WireWriter();
    writer.writeString(1, value.name);
    writer.writeBool(2, value.active);
    final note = value.note;
    if (note != null) {
      writer.writeString(3, note);
    }
    return writer.toBytes();
  }

  @override
  Account decode(Uint8List bytes) {
    final reader = WireReader(bytes);
    var name = '';
    var active = false;
    String? note;
    while (!reader.isAtEnd) {
      final tag = reader.readTag();
      switch (tag.field) {
        case 1:
          name = reader.readString();
        case 2:
          active = reader.readBool();
        case 3:
          note = reader.readString();
        default:
          reader.skip(tag.type);
      }
    }
    return Account(name: name, active: active, note: note);
  }
}

final class TxnAdapter extends CollectionAdapter<Txn> {
  /// [withMemo] models a schema evolution: a `memo` field column (and its
  /// index) added or removed after documents already exist.
  TxnAdapter({this.withMemo = true});

  final bool withMemo;

  @override
  String get model => 'Txn';

  @override
  final pattern = CollectionPattern.parse('accounts/{accountId}/txns');

  @override
  List<FieldColumn<Txn, Object?>> get columns => [
    txnBookedOn,
    txnAmountMinor,
    txnRate,
    txnCurrency,
    txnStatus,
    txnCreatedAt,
    if (withMemo) txnMemo,
  ];

  @override
  List<IndexDef> get indexes => [
    IndexDef.fromFields(['accountId', '-bookedOn']),
    IndexDef.fromFields(['status', 'bookedOn']),
    IndexDef.fromFields(['currency']),
    // The memo index comes and goes with the memo column, exercising the
    // drop-an-index-before-dropping-its-column path.
    if (withMemo) IndexDef.fromFields(['memo']),
    IndexDef.fromFields(['-bookedOn', 'currency']),
  ];

  @override
  Uint8List encode(Txn value) {
    final writer = WireWriter();
    writer.writeInt64(1, value.bookedOn);
    writer.writeSint64(2, value.amountMinor);
    writer.writeDouble(3, value.rate);
    writer.writeString(4, value.currency);
    writer.writeString(5, value.status.name);
    writer.writeInt64(6, value.createdAt.toUtc().microsecondsSinceEpoch);
    final memo = value.memo;
    if (memo != null) {
      writer.writeString(7, memo);
    }
    return writer.toBytes();
  }

  @override
  Txn decode(Uint8List bytes) {
    final reader = WireReader(bytes);
    var bookedOn = 0;
    var amountMinor = 0;
    var rate = 0.0;
    var currency = '';
    var status = TxnStatus.pending;
    var createdAt = DateTime.utc(1970);
    String? memo;
    while (!reader.isAtEnd) {
      final tag = reader.readTag();
      switch (tag.field) {
        case 1:
          bookedOn = reader.readInt64();
        case 2:
          amountMinor = reader.readSint64();
        case 3:
          rate = reader.readDouble();
        case 4:
          currency = reader.readString();
        case 5:
          status = TxnStatus.values.byName(reader.readString());
        case 6:
          createdAt = DateTime.fromMicrosecondsSinceEpoch(
            reader.readInt64(),
            isUtc: true,
          );
        case 7:
          memo = reader.readString();
        default:
          reader.skip(tag.type);
      }
    }
    return Txn(
      bookedOn: bookedOn,
      amountMinor: amountMinor,
      rate: rate,
      currency: currency,
      status: status,
      createdAt: createdAt,
      memo: memo,
    );
  }
}

final class SplitAdapter extends CollectionAdapter<Split> {
  SplitAdapter();

  @override
  String get model => 'Split';

  @override
  final pattern = CollectionPattern.parse(
    'accounts/{accountId}/txns/{txnId}/splits',
  );

  @override
  List<FieldColumn<Split, Object?>> get columns => [
    splitLabel,
    splitShareMinor,
  ];

  @override
  List<IndexDef> get indexes => [
    IndexDef.fromFields(['label']),
  ];

  @override
  Uint8List encode(Split value) {
    final writer = WireWriter();
    writer.writeString(1, value.label);
    writer.writeSint64(2, value.shareMinor);
    return writer.toBytes();
  }

  @override
  Split decode(Uint8List bytes) {
    final reader = WireReader(bytes);
    var label = '';
    var shareMinor = 0;
    while (!reader.isAtEnd) {
      final tag = reader.readTag();
      switch (tag.field) {
        case 1:
          label = reader.readString();
        case 2:
          shareMinor = reader.readSint64();
        default:
          reader.skip(tag.type);
      }
    }
    return Split(label: label, shareMinor: shareMinor);
  }
}

// -- Singletons --------------------------------------------------------------

final accounts = AccountAdapter();
final txns = TxnAdapter();
final txnsWithoutMemo = TxnAdapter(withMemo: false);
final splits = SplitAdapter();

final txnAccountId = ParamColumn(txns.pattern, 'accountId');
final txnTxnId = ParamColumn(splits.pattern, 'txnId');
