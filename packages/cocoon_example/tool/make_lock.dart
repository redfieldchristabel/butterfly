import 'dart:io';

import 'package:cocoon/cocoon.dart';

void main() {
  final lock = SchemaLock(
    version: 2,
    collections: {
      'Account': CollectionSpec(
        model: 'Account',
        path: 'accounts',
        fields: const [
          FieldSpec(name: 'name', number: 1, type: 'String'),
          FieldSpec(name: 'openedAt', number: 2, type: 'DateTime'),
          FieldSpec(name: 'balanceMinor', number: 3, type: 'int'),
          FieldSpec(name: 'active', number: 4, type: 'bool'),
          FieldSpec(name: 'tags', number: 5, type: 'List<String>'),
          FieldSpec(name: 'address', number: 6, type: 'embedded:Address?'),
          FieldSpec(name: 'avatar', number: 7, type: 'Uint8List?'),
        ],
        indexes: const [
          ['name'],
        ],
      ),
      'Txn': CollectionSpec(
        model: 'Txn',
        path: 'accounts/{accountId}/txns',
        fields: const [
          FieldSpec(name: 'bookedOn', number: 1, type: 'int'),
          FieldSpec(name: 'amountMinor', number: 2, type: 'int'),
          FieldSpec(name: 'currency', number: 3, type: 'String'),
          FieldSpec(name: 'status', number: 4, type: 'enum:TxnStatus'),
          FieldSpec(name: 'createdAt', number: 5, type: 'DateTime'),
          FieldSpec(name: 'rate', number: 6, type: 'double'),
          FieldSpec(name: 'memo', number: 7, type: 'String?'),
          FieldSpec(name: 'labels', number: 8, type: 'List<String>'),
          FieldSpec(name: 'receipt', number: 9, type: 'Uint8List?'),
        ],
        indexes: const [
          ['accountId', '-bookedOn'],
          ['status', 'bookedOn'],
        ],
      ),
      'Split': CollectionSpec(
        model: 'Split',
        path: 'accounts/{accountId}/txns/{txnId}/splits',
        fields: const [
          FieldSpec(name: 'label', number: 1, type: 'String'),
          FieldSpec(name: 'shareMinor', number: 2, type: 'int'),
          FieldSpec(name: 'note', number: 3, type: 'String?'),
        ],
        indexes: const [
          ['accountId', 'txnId', '-shareMinor'],
        ],
      ),
    },
    embedded: {
      'Address': EmbeddedSpec(
        name: 'Address',
        fields: const [
          FieldSpec(name: 'city', number: 1, type: 'String'),
          FieldSpec(name: 'postCode', number: 2, type: 'String'),
          FieldSpec(name: 'line2', number: 3, type: 'String?'),
          FieldSpec(name: 'geo', number: 4, type: 'embedded:GeoPoint?'),
        ],
      ),
      'GeoPoint': EmbeddedSpec(
        name: 'GeoPoint',
        fields: const [
          FieldSpec(name: 'lat', number: 1, type: 'double'),
          FieldSpec(name: 'lon', number: 2, type: 'double'),
        ],
      ),
    },
  );
  File('cocoon.lock.json').writeAsStringSync(lock.toSource());
  print(File('cocoon.lock.json').readAsStringSync());
}
