import 'package:cocoon/cocoon.dart';
import 'package:test/test.dart';

DeclaredCollection staff(
  List<DeclaredField> fields, {
  List<List<String>> indexes = const [],
}) => DeclaredCollection(
  model: 'Staff',
  path: 'staff',
  fields: fields,
  indexes: indexes,
);

void main() {
  final v1 = SchemaDiff.compute(SchemaLock.empty(), [
    staff(const [
      DeclaredField('name', 'String'),
      DeclaredField('gender', 'String'),
      DeclaredField('email', 'String'),
      DeclaredField('staffId', 'String'),
    ]),
  ]).resolve().lock;

  test('a new collection is numbered in declaration order', () {
    expect(v1.version, 1);
    expect(v1.collections['Staff']!.fields, const [
      FieldSpec(name: 'name', number: 1, type: 'String'),
      FieldSpec(name: 'gender', number: 2, type: 'String'),
      FieldSpec(name: 'email', number: 3, type: 'String'),
      FieldSpec(name: 'staffId', number: 4, type: 'String'),
    ]);
  });

  test('reordering fields is a no-op', () {
    final diff = SchemaDiff.compute(v1, [
      staff(const [
        DeclaredField('staffId', 'String'),
        DeclaredField('email', 'String'),
        DeclaredField('name', 'String'),
        DeclaredField('gender', 'String'),
      ]),
    ]);
    expect(diff.isEmpty, isTrue);
    expect(diff.resolve().lock.toSource(), v1.toSource());
  });

  group('staffId -> staffUid while reordering', () {
    final diff = SchemaDiff.compute(v1, [
      staff(const [
        DeclaredField('staffUid', 'String'),
        DeclaredField('email', 'String'),
        DeclaredField('name', 'String'),
        DeclaredField('gender', 'String'),
      ]),
    ]);
    final c = diff.collections.single;

    test('only the ambiguous pair needs a decision', () {
      expect(
        c.kept.map((f) => f.name),
        unorderedEquals(['name', 'gender', 'email']),
      );
      expect(c.removed.map((f) => f.name), ['staffId']);
      expect(c.added.map((f) => f.name), ['staffUid']);
      expect(c.needsRenameDecisions, isTrue);
    });

    test('suggests the rename first', () {
      final top = c.candidatesFor(c.removed.single).first;
      expect(top.to.name, 'staffUid');
      expect(top.sameType, isTrue);
      expect(top.similarity, greaterThan(0.8));
    });

    test('rename keeps field number 4 and needs no upgrade', () {
      final resolved = diff.resolve(
        renames: {
          'Staff': {'staffId': 'staffUid'},
        },
      );
      final spec = resolved.lock.collections['Staff']!;
      expect(spec.field('staffUid')!.number, 4);
      expect(spec.field('staffId'), isNull);
      expect(spec.reserved, isEmpty);
      expect(resolved.upgrades, isEmpty);
      expect(resolved.lock.version, 2);
    });

    test('drop + add reserves 4 and gives staffUid number 5', () {
      final spec = diff.resolve().lock.collections['Staff']!;
      expect(spec.field('staffUid')!.number, 5);
      expect(spec.reserved, {4});
    });
  });

  test('a type change moves to a new number and asks for an upgrade step', () {
    final resolved = SchemaDiff.compute(v1, [
      staff(const [
        DeclaredField('name', 'String'),
        DeclaredField('gender', 'String'),
        DeclaredField('email', 'String'),
        DeclaredField('staffId', 'int'),
      ]),
    ]).resolve();
    final spec = resolved.lock.collections['Staff']!;
    expect(
      spec.field('staffId'),
      const FieldSpec(name: 'staffId', number: 5, type: 'int'),
    );
    expect(spec.reserved, {4});
    expect(resolved.upgrades['Staff'], const [
      FieldUpgrade(
        from: FieldSpec(name: 'staffId', number: 4, type: 'String'),
        to: FieldSpec(name: 'staffId', number: 5, type: 'int'),
      ),
    ]);
  });

  test('rename + type change is an upgrade, never a silent reuse', () {
    final resolved =
        SchemaDiff.compute(v1, [
          staff(const [
            DeclaredField('name', 'String'),
            DeclaredField('gender', 'String'),
            DeclaredField('email', 'String'),
            DeclaredField('staffNo', 'int'),
          ]),
        ]).resolve(
          renames: {
            'Staff': {'staffId': 'staffNo'},
          },
        );
    expect(resolved.lock.collections['Staff']!.field('staffNo')!.number, 5);
    expect(resolved.upgrades['Staff']!.single.from.name, 'staffId');
  });

  test('reserved numbers are never reused', () {
    final dropped = SchemaDiff.compute(v1, [
      staff(const [DeclaredField('name', 'String')]),
    ]).resolve().lock;
    expect(dropped.collections['Staff']!.reserved, {2, 3, 4});
    final readded = SchemaDiff.compute(dropped, [
      staff(const [
        DeclaredField('name', 'String'),
        DeclaredField('email', 'String'),
      ]),
    ]).resolve().lock;
    expect(readded.collections['Staff']!.field('email')!.number, 5);
  });

  test('rejects bad rename decisions', () {
    final diff = SchemaDiff.compute(v1, [
      staff(const [
        DeclaredField('name', 'String'),
        DeclaredField('uid', 'String'),
      ]),
    ]);
    expect(
      () => diff.resolve(
        renames: {
          'Staff': {'name': 'uid'},
        },
      ),
      throwsArgumentError,
    );
    expect(
      () => diff.resolve(
        renames: {
          'Staff': {'email': 'nope'},
        },
      ),
      throwsArgumentError,
    );
    expect(
      () => diff.resolve(
        renames: {
          'Staff': {'email': 'uid', 'staffId': 'uid'},
        },
      ),
      throwsArgumentError,
    );
    expect(() => diff.resolve(renames: {'Ghost': {}}), throwsArgumentError);
  });

  test('validates indexes and path params', () {
    expect(
      () => SchemaDiff.compute(SchemaLock.empty(), [
        DeclaredCollection(
          model: 'Txn',
          path: 'accounts/{accountId}/txns',
          fields: const [DeclaredField('bookedOn', 'int')],
          indexes: const [
            ['accountId', '-bookedOn'],
          ],
        ),
      ]),
      returnsNormally,
    );
    expect(
      () => SchemaDiff.compute(SchemaLock.empty(), [
        staff(
          const [DeclaredField('name', 'String')],
          indexes: const [
            ['-missing'],
          ],
        ),
      ]),
      throwsArgumentError,
    );
    expect(
      () => SchemaDiff.compute(SchemaLock.empty(), [
        DeclaredCollection(
          model: 'Txn',
          path: 'accounts/{accountId}/txns',
          fields: const [DeclaredField('accountId', 'String')],
        ),
      ]),
      throwsArgumentError,
    );
  });

  test('index changes and dropped collections show up in the diff', () {
    final withIndex = SchemaDiff.compute(v1, [
      staff(
        v1.collections['Staff']!.fields
            .map((f) => DeclaredField(f.name, f.type))
            .toList(),
        indexes: const [
          ['email'],
        ],
      ),
    ]);
    expect(withIndex.collections.single.indexesChanged, isTrue);
    expect(withIndex.isEmpty, isFalse);

    final gone = SchemaDiff.compute(v1, const []);
    expect(gone.removedCollections.single.model, 'Staff');
    expect(gone.isEmpty, isFalse);
  });

  test('lock file text is deterministic and round-trips', () {
    final source = v1.toSource();
    expect(SchemaLock.parse(source).toSource(), source);
    expect(source, contains('"staffId": {\n'));
    expect(() => SchemaLock.parse('{"format": 99}'), throwsFormatException);
  });
}
