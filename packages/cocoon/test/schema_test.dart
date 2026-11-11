import 'dart:convert';

import 'package:cocoon/cocoon.dart';
import 'package:test/test.dart';

DeclaredCollection staff(
  List<DeclaredField> fields, {
  List<List<String>> indexes = const [],
  List<String> mirrored = const [],
}) => DeclaredCollection(
  model: 'Staff',
  path: 'staff',
  fields: fields,
  indexes: indexes,
  mirrored: mirrored,
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

  test('the YAML lock file parses to the same lock as its JSON', () {
    // The shape `cocoon_generator migrate` writes: a header comment, block
    // style, plain scalars wherever YAML allows them (`-bookedOn` needs no
    // quotes), `[]` for the empty list.
    const yaml = '''
# Generated by cocoon_generator migrate. Do not edit by hand.
# Pins every field number, collection path, index and recorded migration decision of this package's Cocoon schema.
format: 1
version: 3
collections:
  Staff:
    path: staff
    fields:
      name:
        number: 1
        type: String
      total:
        number: 2
        type: int
    reserved: []
    indexes:
      - - name
      - - accountId
        - -bookedOn
    mirrored:
      - total
embedded:
  Badge:
    fields:
      code:
        number: 1
        type: String
    reserved: []
''';
    const json =
        '{"format": 1, "version": 3, "collections": {"Staff": {'
        '"path": "staff", '
        '"fields": {"name": {"number": 1, "type": "String"}, '
        '"total": {"number": 2, "type": "int"}}, '
        '"reserved": [], '
        '"indexes": [["name"], ["accountId", "-bookedOn"]], '
        '"mirrored": ["total"]}}, '
        '"embedded": {"Badge": {"fields": '
        '{"code": {"number": 1, "type": "String"}}, "reserved": []}}}';
    final fromYaml = SchemaLock.parse(yaml);
    final fromJson = SchemaLock.parse(json);
    // The engine fingerprints `jsonEncode(lock.toJson())`: the same lock as
    // YAML and as JSON must give the same fingerprint, so nothing re-migrates.
    expect(jsonEncode(fromYaml.toJson()), jsonEncode(fromJson.toJson()));
    expect(fromYaml.version, 3);
    expect(fromYaml.collections['Staff']!.mirrored, ['total']);
    expect(fromYaml.collections['Staff']!.indexes, [
      ['name'],
      ['accountId', '-bookedOn'],
    ]);
    expect(fromYaml.embedded['Badge']!.field('code')!.number, 1);
  });

  test('the YAML reader quotes what it must and rejects what it cannot', () {
    const yaml = '''
format: 1
version: 1
collections:
  Staff:
    path: staff
    fields:
      'no':
        number: 1
        type: 'Map<String,int>'
      tag:
        number: 2
        type: "String"
    reserved: []
    indexes: []
''';
    final lock = SchemaLock.parse(yaml);
    final staff = lock.collections['Staff']!;
    expect(staff.field('no')!.type, 'Map<String,int>');
    expect(staff.field('tag')!.type, 'String');

    expect(
      () => SchemaLock.parse('format: 1\nversion: 1\n  oops: 2'),
      throwsFormatException,
    );
    expect(
      () => SchemaLock.parse('format: 1\nversion:'),
      throwsFormatException,
    );
  });

  group('embedded classes', () {
    DeclaredEmbedded address(List<DeclaredField> fields) =>
        DeclaredEmbedded('Address', fields);

    test('a new embedded class is numbered in its own space', () {
      final resolved = SchemaDiff.compute(
        SchemaLock.empty(),
        [
          staff(const [DeclaredField('name', 'String')]),
        ],
        [
          address(const [
            DeclaredField('city', 'String'),
            DeclaredField('line2', 'String?'),
          ]),
        ],
      ).resolve();
      final lock = resolved.lock;
      expect(lock.version, 1);
      final spec = lock.embedded['Address']!;
      expect(spec.fields, const [
        FieldSpec(name: 'city', number: 1, type: 'String'),
        FieldSpec(name: 'line2', number: 2, type: 'String?'),
      ]);
      expect(spec.reserved, isEmpty);
      // The collection's numbers are unaffected by the embedded class.
      expect(lock.collections['Staff']!.field('name')!.number, 1);
    });

    test('embedded entries round-trip through the lock text', () {
      final withEmbedded = SchemaDiff.compute(
        SchemaLock.empty(),
        [
          staff(const [DeclaredField('name', 'String')]),
        ],
        [
          address(const [DeclaredField('city', 'String')]),
        ],
      ).resolve().lock;
      final source = withEmbedded.toSource();
      expect(source, contains('"embedded"'));
      expect(SchemaLock.parse(source).toSource(), source);
    });

    test('a lock without embedded entries parses as none', () {
      expect(v1.embedded, isEmpty);
      expect(v1.toSource(), isNot(contains('"embedded"')));
    });

    test('a type change moves the embedded field to a new number', () {
      final locked = SchemaDiff.compute(SchemaLock.empty(), [], [
        address(const [DeclaredField('city', 'String')]),
      ]).resolve().lock;

      final resolved = SchemaDiff.compute(locked, [], [
        address(const [DeclaredField('city', 'int')]),
      ]).resolve();
      final spec = resolved.lock.embedded['Address']!;
      expect(spec.field('city')!.number, 2);
      expect(spec.reserved, {1});
      expect(resolved.upgrades['Address']!.single.from.type, 'String');
    });

    test('renames resolve without renumbering', () {
      final locked = SchemaDiff.compute(SchemaLock.empty(), [], [
        address(const [
          DeclaredField('city', 'String'),
          DeclaredField('zip', 'String'),
        ]),
      ]).resolve().lock;

      final resolved =
          SchemaDiff.compute(locked, [], [
            address(const [
              DeclaredField('city', 'String'),
              DeclaredField('postCode', 'String'),
            ]),
          ]).resolve(
            embeddedRenames: {
              'Address': {'zip': 'postCode'},
            },
          );
      expect(resolved.lock.embedded['Address']!.field('postCode')!.number, 2);
      expect(resolved.lock.embedded['Address']!.reserved, isEmpty);
      expect(resolved.upgrades, isEmpty);
      expect(resolved.lock.version, 2);
    });

    test('dropping every reference drops the lock entry', () {
      final locked = SchemaDiff.compute(SchemaLock.empty(), [], [
        address(const [DeclaredField('city', 'String')]),
      ]).resolve().lock;

      final resolved = SchemaDiff.compute(locked, []).resolve();
      expect(resolved.lock.embedded, isEmpty);
      // Like a dropped collection, an unreferenced embedded class needs no
      // device-side migration: old documents simply carry extra nested data.
      expect(resolved.lock.version, locked.version);
    });

    test('an embedded class may not be declared twice', () {
      expect(
        () => SchemaDiff.compute(SchemaLock.empty(), const [], [
          address(const [DeclaredField('city', 'String')]),
          address(const [DeclaredField('line2', 'String?')]),
        ]),
        throwsArgumentError,
      );
    });

    test('nullability is part of the type', () {
      final locked = SchemaDiff.compute(SchemaLock.empty(), [], [
        address(const [DeclaredField('city', 'String')]),
      ]).resolve().lock;
      final diff = SchemaDiff.compute(locked, [], [
        address(const [DeclaredField('city', 'String?')]),
      ]);
      expect(diff.embedded.single.typeChanged, hasLength(1));
      expect(diff.isEmpty, isFalse);
    });
  });

  group('mirrored fields', () {
    test('the lock records them and round-trips; empty omits the key', () {
      final locked = SchemaDiff.compute(SchemaLock.empty(), [
        staff(
          const [
            DeclaredField('name', 'String'),
            DeclaredField('total', 'int'),
          ],
          indexes: [
            ['name'],
          ],
          mirrored: ['total'],
        ),
      ]).resolve().lock;
      expect(locked.collections['Staff']!.mirrored, ['total']);
      expect(locked.toSource(), contains('"mirrored"'));

      final parsed = SchemaLock.parse(locked.toSource());
      expect(parsed.collections['Staff']!.mirrored, ['total']);

      // A collection without mirrored fields keeps the old lock shape.
      final plain = SchemaDiff.compute(SchemaLock.empty(), [
        staff(const [DeclaredField('name', 'String')]),
      ]).resolve().lock;
      expect(plain.toSource(), isNot(contains('"mirrored"')));
    });

    test('a lock written before mirroring parses with none', () {
      final source = '''
{
  "format": 1,
  "version": 3,
  "collections": {
    "Staff": {
      "path": "staff",
      "fields": {"name": {"number": 1, "type": "String"}},
      "reserved": [],
      "indexes": [["name"]]
    }
  }
}
''';
      final lock = SchemaLock.parse(source);
      expect(lock.collections['Staff']!.mirrored, isEmpty);
      // Re-serializing keeps the shape (the key stays absent).
      expect(lock.toSource(), isNot(contains('"mirrored"')));
    });

    test('adding @Mirrored() changes the diff and bumps the version', () {
      final before = SchemaDiff.compute(SchemaLock.empty(), [
        staff(
          const [
            DeclaredField('name', 'String'),
            DeclaredField('total', 'int'),
          ],
          indexes: [
            ['name'],
          ],
        ),
      ]).resolve().lock;

      final diff = SchemaDiff.compute(before, [
        staff(
          const [
            DeclaredField('name', 'String'),
            DeclaredField('total', 'int'),
          ],
          indexes: [
            ['name'],
          ],
          mirrored: ['total'],
        ),
      ]);
      expect(diff.collections.single.mirroredChanged, isTrue);
      expect(diff.isEmpty, isFalse);

      final resolved = diff.resolve();
      expect(resolved.lock.version, 2);
      expect(resolved.lock.collections['Staff']!.mirrored, ['total']);
      // No field moved and no rewrite is needed: the column backfills at open.
      expect(resolved.upgrades, isEmpty);
      expect(resolved.lock.collections['Staff']!.field('total')!.number, 2);
    });

    test('removing @Mirrored() changes the diff back', () {
      final before = SchemaDiff.compute(SchemaLock.empty(), [
        staff(const [DeclaredField('name', 'String')], mirrored: ['name']),
      ]).resolve().lock;
      expect(before.collections['Staff']!.mirrored, ['name']);

      final diff = SchemaDiff.compute(before, [
        staff(const [DeclaredField('name', 'String')]),
      ]);
      expect(diff.isEmpty, isFalse);
      expect(diff.resolve().lock.collections['Staff']!.mirrored, isEmpty);
    });

    test('mirroring an unknown field or a Map field is refused', () {
      expect(
        () => CollectionDiff.compute(
          null,
          staff(const [DeclaredField('name', 'String')], mirrored: ['nope']),
        ),
        throwsArgumentError,
      );
      expect(
        () => CollectionDiff.compute(
          null,
          staff(
            const [DeclaredField('meta', 'Map<String,int>')],
            mirrored: ['meta'],
          ),
        ),
        throwsArgumentError,
      );
    });
  });
}
