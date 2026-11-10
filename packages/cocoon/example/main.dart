// A runnable tour of Cocoon's core API — open, write, read, query,
// aggregate and watch — that needs no code generation: the hand-written
// adapter below stands in for the one `cocoon_generator` would emit from a
// `@Collection` model (same shape, same column handles, same canonical
// codec). See the README's "Writing an adapter by hand" section, and the
// `cocoon_example` package for the full generated flow.
//
// Run it from this package:
//
//     dart run example/main.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cocoon/cocoon.dart';

/// A stored model: a plain class with final fields.
class Txn {
  const Txn({
    required this.label,
    required this.bookedOn,
    required this.amountMinor,
  });

  final String label;
  final int bookedOn; // yyyymmdd
  final int amountMinor; // minor units; may be negative

  @override
  String toString() => 'Txn($label, $bookedOn, $amountMinor)';
}

// Typed column handles, one per indexed field (what the generator emits as
// `Txn$.bookedOn`, ...). The engine mirrors these into real SQLite columns.
final txnBookedOn = FieldColumn.integer<Txn, int>(
  'bookedOn',
  read: (t) => t.bookedOn,
);
final txnAmountMinor = FieldColumn.integer<Txn, int>(
  'amountMinor',
  read: (t) => t.amountMinor,
);
final txnLabel = FieldColumn.text<Txn, String>('label', read: (t) => t.label);

final class TxnAdapter extends CollectionAdapter<Txn> {
  @override
  String get model => 'Txn';

  @override
  final pattern = CollectionPattern.parse('txns');

  @override
  List<FieldColumn<Txn, Object?>> get columns => [
    txnBookedOn,
    txnAmountMinor,
    txnLabel,
  ];

  @override
  List<IndexDef> get indexes => [
    // '-' prefixes a descending part, like @Collection(indexes:
    // [Index(['-bookedOn'])]).
    IndexDef.fromFields(['-bookedOn']),
  ];

  @override
  Uint8List encode(Txn value) {
    final writer = WireWriter();
    writer.writeString(1, value.label);
    writer.writeInt64(2, value.bookedOn);
    writer.writeSint64(3, value.amountMinor); // zigzag: safe for negatives
    return writer.toBytes();
  }

  @override
  Txn decode(Uint8List bytes) {
    final reader = WireReader(bytes);
    var label = '';
    var bookedOn = 0;
    var amountMinor = 0;
    while (!reader.isAtEnd) {
      final tag = reader.readTag();
      switch (tag.field) {
        case 1:
          label = reader.readString();
        case 2:
          bookedOn = reader.readInt64();
        case 3:
          amountMinor = reader.readSint64();
        default:
          reader.skip(tag.type); // unknown fields from the future
      }
    }
    return Txn(label: label, bookedOn: bookedOn, amountMinor: amountMinor);
  }
}

final txns = TxnAdapter();

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('cocoon_example');
  try {
    final db = await Cocoon.open('${dir.path}/wallet.db', collections: [txns]);

    // Write and read one document (set is an upsert by id).
    final coffee = db.collection(txns).doc('coffee-1');
    await coffee.set(
      Txn(label: 'coffee', bookedOn: 20261110, amountMinor: -1250),
    );
    final snap = await coffee.get();
    print('Read back: ${snap!.data} (id ${snap.id})');

    await db
        .collection(txns)
        .doc('tea-1')
        .set(Txn(label: 'tea', bookedOn: 20261109, amountMinor: -430));
    await db
        .collection(txns)
        .doc('salary-1')
        .set(Txn(label: 'salary', bookedOn: 20261101, amountMinor: 500000));

    // A query: runs only when an index serves it — the '-bookedOn' index
    // above covers this range filter plus the descending sort. Pages come
    // back with an opaque cursor for the next page (null on the last one).
    final page = await db
        .collection(txns)
        .where(txnBookedOn.isGreaterThanOrEqualTo(20261101))
        .orderBy(txnBookedOn, descending: true)
        .limit(10)
        .get();
    print('Query: ${page.docs.map((d) => d.data.label).join(', ')}');

    // An aggregate: computed in SQLite over the mirrored columns, with no
    // documents decoded. Empty sum is 0; count is Firestore's COUNT(*).
    final totals = await db.collection(txns).aggregate([
      count(),
      sum(txnAmountMinor),
    ]).get();
    print(
      'Aggregate: ${totals.count} documents, '
      'balance ${totals.getSum(txnAmountMinor)} minor units',
    );

    // Watch one document: emits the current value on listen, then again
    // only when a commit changes this exact document. A rewrite that
    // encodes to the same bytes never emits.
    var emission = 0;
    final sawUpdate = Completer<void>();
    final sub = coffee.watch().listen((snap) {
      emission++;
      print('Watch #$emission: ${snap?.data}');
      if (emission == 2) sawUpdate.complete();
    });
    await coffee.set(
      Txn(label: 'coffee (refilled)', bookedOn: 20261110, amountMinor: -2500),
    );
    await sawUpdate.future;
    await sub.cancel();

    await db.close();
    print('Done.');
  } finally {
    dir.deleteSync(recursive: true);
  }
}
