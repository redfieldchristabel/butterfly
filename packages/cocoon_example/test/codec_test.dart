/// Codec tests over the generated adapters: canonical bytes equal a
/// hand-written `WireWriter` encoding, old documents decode with defaults,
/// unknown fields are skipped, and the schema version constant matches the
/// committed lock.
///
/// These tests are pure Dart: no database involved.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cocoon/cocoon.dart';
import 'package:cocoon_example/cocoon_schema.g.dart';
import 'package:cocoon_example/models.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('account bytes are the canonical hand-written encoding', () {
    final account = accountFixture(name: 'Acme Holdings');
    final writer = WireWriter();
    writer.writeString(1, account.name);
    writer.writeSint64(2, account.openedAt.toUtc().microsecondsSinceEpoch);
    writer.writeSint64(3, account.balanceMinor);
    writer.writeBool(4, account.active);
    writer.writeMessage(5, (nested) {
      var i = 1;
      for (final tag in account.tags) {
        nested.writeString(i, tag);
        i++;
      }
    });
    Address$.writeTo(writer, 6, account.address!);
    writer.writeBytes(7, account.avatar!);

    expect(accounts.encode(account), writer.toBytes());
  });

  test('txn bytes are the canonical hand-written encoding', () {
    final txn = txnFixture();
    final writer = WireWriter();
    writer.writeSint64(1, txn.bookedOn);
    writer.writeSint64(2, txn.amountMinor); // negative: zigzag sint64
    writer.writeString(3, txn.currency);
    writer.writeString(4, txn.status.name);
    writer.writeSint64(5, txn.createdAt.toUtc().microsecondsSinceEpoch);
    writer.writeDouble(6, txn.rate);
    writer.writeString(7, txn.memo!);
    writer.writeMessage(8, (nested) {
      var i = 1;
      for (final label in txn.labels) {
        nested.writeString(i, label);
        i++;
      }
    });
    writer.writeBytes(9, txn.receipt!);

    expect(txns.encode(txn), writer.toBytes());
  });

  test('empty lists encode as present-but-empty messages', () {
    final txn = Txn(
      bookedOn: 1,
      amountMinor: 0,
      currency: 'MYR',
      status: TxnStatus.pending,
      createdAt: DateTime.utc(2026),
      rate: 1,
      labels: const [],
    );
    final writer = WireWriter();
    writer.writeSint64(1, 1);
    writer.writeSint64(2, 0);
    writer.writeString(3, 'MYR');
    writer.writeString(4, 'pending');
    writer.writeSint64(5, DateTime.utc(2026).microsecondsSinceEpoch);
    writer.writeDouble(6, 1);
    writer.writeMessage(8, (nested) {});

    expect(txns.encode(txn), writer.toBytes());
  });

  test('nulls are skipped in the encoding', () {
    final txn = Txn(
      bookedOn: 1,
      amountMinor: 0,
      currency: 'MYR',
      status: TxnStatus.pending,
      createdAt: DateTime.utc(2026),
      rate: 1,
    );
    // Fields 7 (memo) and 9 (receipt) are null; 8 (labels) is empty but
    // present.
    final reader = WireReader(txns.encode(txn));
    final numbers = <int>[];
    while (!reader.isAtEnd) {
      final tag = reader.readTag();
      numbers.add(tag.field);
      reader.skip(tag.type);
    }
    expect(numbers, [1, 2, 3, 4, 5, 6, 8]);
  });

  test(
    'round trips preserve every value (byte equality is value equality)',
    () {
      final account = accountFixture(name: 'Acme Holdings');
      final accountBack = accounts.decode(accounts.encode(account));
      expect(accounts.encode(accountBack), accounts.encode(account));

      final txn = txnFixture();
      final txnBack = txns.decode(txns.encode(txn));
      expect(txns.encode(txnBack), txns.encode(txn));
      // Spot-check the values the bytes stand for.
      expect(txnBack.amountMinor, -4299);
      expect(txnBack.status, TxnStatus.posted);
      expect(txnBack.createdAt, DateTime.utc(2026, 1, 15, 12, 0, 30, 250, 999));
      expect(txnBack.rate, 4.123456);
      expect(txnBack.labels, ['food', 'weekly']);

      final split = splitFixture(label: 'rent', shareMinor: 700);
      final splitBack = splits.decode(splits.encode(split));
      expect(splitBack.label, 'rent');
      expect(splitBack.shareMinor, 700);
      expect(splitBack.note, isNull);
    },
  );

  test('a document written before memo/labels/receipt existed decodes with '
      'defaults', () {
    // The encoding an old schema version produced: fields 1-6 only.
    final old = WireWriter();
    old.writeSint64(1, 20260110);
    old.writeSint64(2, -1200);
    old.writeString(3, 'SGD');
    old.writeString(4, TxnStatus.pending.name);
    old.writeSint64(5, DateTime.utc(2026, 1, 10, 8).microsecondsSinceEpoch);
    old.writeDouble(6, 0.31);

    final txn = txns.decode(old.toBytes());
    expect(txn.bookedOn, 20260110);
    expect(txn.amountMinor, -1200);
    expect(txn.currency, 'SGD');
    expect(txn.status, TxnStatus.pending);
    expect(txn.createdAt, DateTime.utc(2026, 1, 10, 8));
    expect(txn.rate, 0.31);
    // Missing nullable fields decode to null.
    expect(txn.memo, isNull);
    expect(txn.receipt, isNull);
    // A missing field with a constructor default uses that default.
    expect(txn.labels, isEmpty);
    // And it re-encodes to exactly the old bytes' known fields.
    final reader = WireReader(txns.encode(txn));
    final numbers = <int>[];
    while (!reader.isAtEnd) {
      final tag = reader.readTag();
      numbers.add(tag.field);
      reader.skip(tag.type);
    }
    expect(numbers, [1, 2, 3, 4, 5, 6, 8]);
  });

  test('unknown field numbers from the future are skipped', () {
    // Fields 1-6 of an old schema, plus field 50 that a newer version wrote.
    final writer = WireWriter();
    writer.writeSint64(1, 20260110);
    writer.writeSint64(2, -1200);
    writer.writeString(3, 'SGD');
    writer.writeString(4, TxnStatus.pending.name);
    writer.writeSint64(5, DateTime.utc(2026, 1, 10, 8).microsecondsSinceEpoch);
    writer.writeDouble(6, 0.31);
    writer.writeString(50, 'a field from the future');

    final txn = txns.decode(writer.toBytes());
    expect(txn.bookedOn, 20260110);
    expect(txn.currency, 'SGD');
    expect(txn.memo, isNull);
  });

  test('an empty blob decodes to proto3 zeros and constructor defaults', () {
    final txn = txns.decode(Uint8List(0));
    expect(txn.bookedOn, 0);
    expect(txn.amountMinor, 0);
    expect(txn.currency, '');
    expect(txn.status, TxnStatus.pending); // first enum value
    expect(txn.createdAt, DateTime.utc(1970));
    expect(txn.rate, 0.0);
    expect(txn.memo, isNull);
    expect(txn.labels, isEmpty); // constructor default
    expect(txn.receipt, isNull);

    final split = splits.decode(Uint8List(0));
    expect(split.label, '');
    expect(split.shareMinor, 0);
    expect(split.note, isNull);
  });

  test('the generated schema version constant matches the committed lock', () {
    final lock =
        jsonDecode(File('cocoon.lock.json').readAsStringSync())
            as Map<String, Object?>;
    expect(cocoonSchemaVersion, lock['version']);
  });
}
