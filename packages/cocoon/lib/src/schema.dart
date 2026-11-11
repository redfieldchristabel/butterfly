import 'dart:convert';
import 'dart:math' as math;

import 'package:meta/meta.dart';

import 'lock_text.dart';
import 'path.dart';

/// The lock file format version.
const schemaLockFormat = 1;

/// A field as the model declares it: a name and a type, no number.
///
/// [type] is the generator's canonical type name, e.g. `int`, `String`,
/// `DateTime`, `List<String>` or a nested model name.
@immutable
class DeclaredField {
  /// Declares the field [name] of canonical type [type].
  const DeclaredField(this.name, this.type);

  /// The field name in the model.
  final String name;

  /// The field's canonical type name.
  final String type;

  @override
  bool operator ==(Object other) =>
      other is DeclaredField && other.name == name && other.type == type;

  @override
  int get hashCode => Object.hash(name, type);

  @override
  String toString() => '$name: $type';
}

/// A collection as the model declares it, read from `@Collection`.
@immutable
class DeclaredCollection {
  /// Declares the collection [model] at [path] with its [fields], [indexes]
  /// and [mirrored] names, as read from the annotations.
  DeclaredCollection({
    required this.model,
    required this.path,
    required List<DeclaredField> fields,
    List<List<String>> indexes = const [],
    List<String> mirrored = const [],
  }) : fields = List.unmodifiable(fields),
       indexes = List<List<String>>.unmodifiable(
         indexes.map(List<String>.unmodifiable),
       ),
       mirrored = List<String>.unmodifiable(mirrored);

  /// The model class name; the lock is keyed by it.
  final String model;

  /// The collection path pattern, e.g. `accounts/{accountId}/txns`.
  final String path;

  /// Fields in declaration order. Order only affects numbering of a brand-new
  /// collection; afterwards numbers come from the lock.
  final List<DeclaredField> fields;

  /// Index field lists, `-` prefix for descending.
  final List<List<String>> indexes;

  /// Field names annotated `@Mirrored()`: stored in their own `f_` column
  /// (aggregates read it) without an index.
  final List<String> mirrored;
}

/// An embedded class as the models declare it, read from `@Embedded`.
@immutable
class DeclaredEmbedded {
  /// Declares the embedded class [name] with its [fields].
  DeclaredEmbedded(this.name, List<DeclaredField> fields)
    : fields = List.unmodifiable(fields);

  /// The embedded class name; the lock keys its entry by it.
  final String name;

  /// Fields in declaration order. Order only affects numbering of a
  /// brand-new embedded class; afterwards numbers come from the lock.
  final List<DeclaredField> fields;
}

/// A field pinned in the lock: its number is its identity on disk.
@immutable
class FieldSpec {
  /// Pins [name] at [number] with the wire type string [type].
  const FieldSpec({
    required this.name,
    required this.number,
    required this.type,
  });

  /// The field name in the model.
  final String name;

  /// The field number: the field's identity on disk, never reused.
  final int number;

  /// The field's type, as the wire codec spells it (e.g. `int`, `String`,
  /// `List<String>`).
  final String type;

  /// The lock's JSON shape for this field (number and type; the name is the
  /// JSON key).
  Map<String, Object> toJson() => {'number': number, 'type': type};

  @override
  bool operator ==(Object other) =>
      other is FieldSpec &&
      other.name == name &&
      other.number == number &&
      other.type == type;

  @override
  int get hashCode => Object.hash(name, number, type);

  @override
  String toString() => '$name #$number: $type';
}

/// A collection pinned in the lock.
@immutable
class CollectionSpec {
  /// Pins [model] at [path]; [fields] is stored sorted by number.
  CollectionSpec({
    required this.model,
    required this.path,
    required List<FieldSpec> fields,
    Set<int> reserved = const {},
    List<List<String>> indexes = const [],
    List<String> mirrored = const [],
    List<String> keepZero = const [],
  }) : fields = List<FieldSpec>.unmodifiable(
         List<FieldSpec>.of(fields)
           ..sort((FieldSpec a, FieldSpec b) => a.number.compareTo(b.number)),
       ),
       reserved = Set<int>.unmodifiable(reserved),
       indexes = List<List<String>>.unmodifiable(
         indexes.map(List<String>.unmodifiable),
       ),
       mirrored = List<String>.unmodifiable(mirrored),
       keepZero = List<String>.unmodifiable(keepZero);

  /// Restores the lock entry [model] from the lock file's JSON shape.
  factory CollectionSpec.fromJson(String model, Map<String, Object?> json) {
    final fields = (json['fields']! as Map<String, Object?>).entries.map((e) {
      final value = e.value! as Map<String, Object?>;
      return FieldSpec(
        name: e.key,
        number: value['number']! as int,
        type: value['type']! as String,
      );
    }).toList();
    return CollectionSpec(
      model: model,
      path: json['path']! as String,
      fields: fields,
      reserved: {
        ...(json['reserved'] as List<Object?>? ?? const []).cast<int>(),
      },
      indexes: [
        for (final index in json['indexes'] as List<Object?>? ?? const [])
          (index! as List<Object?>).cast<String>(),
      ],
      mirrored: [
        for (final name in json['mirrored'] as List<Object?>? ?? const [])
          name! as String,
      ],
      keepZero: [
        for (final name in json['keepZero'] as List<Object?>? ?? const [])
          name! as String,
      ],
    );
  }

  /// The model (class) name this entry pins.
  final String model;

  /// The collection path pattern, e.g. `accounts/{accountId}/txns`.
  final String path;

  /// Fields sorted by number.
  final List<FieldSpec> fields;

  /// Numbers of dropped fields. They are never reused, so old data can't be
  /// misread as a new field.
  final Set<int> reserved;

  /// The declared `Index([...])` sets, as field-name parts (`-` prefixes a
  /// descending part).
  final List<List<String>> indexes;

  /// Field names annotated `@Mirrored()`: their `f_` column exists but no
  /// index does. Recorded so a later diff sees mirrored changes (the
  /// on-device open backfills or drops the column) and the DevTools
  /// inspector can label them.
  final List<String> mirrored;

  /// Fields whose added-and-required question was answered "keep the zero
  /// value": the field is non-nullable without a constructor default, and
  /// existing documents knowingly read the proto3 zero instead of a
  /// backfilled value. Recorded so the migrate command never asks again.
  final List<String> keepZero;

  /// The field with [name], or `null` when it is not pinned.
  FieldSpec? field(String name) {
    for (final f in fields) {
      if (f.name == name) return f;
    }
    return null;
  }

  /// The next number that has never been used by this collection.
  int get nextNumber =>
      [0, ...fields.map((f) => f.number), ...reserved].reduce(math.max) + 1;

  /// The lock file's JSON shape for this entry (the model name is the key).
  Map<String, Object> toJson() => {
    'path': path,
    'fields': {for (final f in fields) f.name: f.toJson()},
    'reserved': [...reserved]..sort(),
    'indexes': indexes,
    // Omitted when empty, so locks written before mirroring existed still
    // round-trip byte-for-byte through this format.
    if (mirrored.isNotEmpty) 'mirrored': mirrored,
    if (keepZero.isNotEmpty) 'keepZero': keepZero,
  };
}

/// An embedded class pinned in the lock.
///
/// Like a [CollectionSpec], but without a path or indexes: an embedded class
/// is stored inline inside its owning documents and never queried directly.
@immutable
class EmbeddedSpec {
  /// Pins the embedded class [name]; [fields] is stored sorted by number.
  EmbeddedSpec({
    required this.name,
    required List<FieldSpec> fields,
    Set<int> reserved = const {},
  }) : fields = List<FieldSpec>.unmodifiable(
         List<FieldSpec>.of(fields)
           ..sort((FieldSpec a, FieldSpec b) => a.number.compareTo(b.number)),
       ),
       reserved = Set<int>.unmodifiable(reserved);

  /// Restores the lock entry [name] from the lock file's JSON shape.
  factory EmbeddedSpec.fromJson(String name, Map<String, Object?> json) {
    final fields = (json['fields']! as Map<String, Object?>).entries.map((e) {
      final value = e.value! as Map<String, Object?>;
      return FieldSpec(
        name: e.key,
        number: value['number']! as int,
        type: value['type']! as String,
      );
    }).toList();
    return EmbeddedSpec(
      name: name,
      fields: fields,
      reserved: {
        ...(json['reserved'] as List<Object?>? ?? const []).cast<int>(),
      },
    );
  }

  /// The embedded class name, e.g. `Address`.
  final String name;

  /// Fields sorted by number.
  final List<FieldSpec> fields;

  /// Numbers of dropped fields. They are never reused, so old data can't be
  /// misread as a new field.
  final Set<int> reserved;

  /// The field with [name], or `null` when it is not pinned.
  FieldSpec? field(String name) {
    for (final f in fields) {
      if (f.name == name) return f;
    }
    return null;
  }

  /// The next number that has never been used by this embedded class.
  int get nextNumber =>
      [0, ...fields.map((f) => f.number), ...reserved].reduce(math.max) + 1;

  /// The lock file's JSON shape for this entry (the class name is the key).
  Map<String, Object> toJson() => {
    'fields': {for (final f in fields) f.name: f.toJson()},
    'reserved': [...reserved]..sort(),
  };
}

/// The committed `cocoon.lock`: the source of truth for field numbers.
@immutable
class SchemaLock {
  /// Builds a lock from parsed pieces; prefer [parse]/[fromJson] for files.
  SchemaLock({
    required this.version,
    required Map<String, CollectionSpec> collections,
    Map<String, EmbeddedSpec> embedded = const {},
  }) : collections = Map.unmodifiable(collections),
       embedded = Map.unmodifiable(embedded);

  /// An empty lock for a project that has never generated a migration.
  factory SchemaLock.empty() =>
      SchemaLock(version: 0, collections: const {}, embedded: const {});

  /// Restores the lock from its file (must carry the current `format`).
  factory SchemaLock.fromJson(Map<String, Object?> json) {
    final format = json['format'];
    if (format != schemaLockFormat) {
      throw FormatException('Unsupported cocoon.lock format $format');
    }
    final collections = json['collections']! as Map<String, Object?>;
    final embedded = json['embedded'] as Map<String, Object?>? ?? const {};
    return SchemaLock(
      version: json['version']! as int,
      collections: {
        for (final e in collections.entries)
          e.key: CollectionSpec.fromJson(
            e.key,
            e.value! as Map<String, Object?>,
          ),
      },
      embedded: {
        for (final e in embedded.entries)
          e.key: EmbeddedSpec.fromJson(e.key, e.value! as Map<String, Object?>),
      },
    );
  }

  /// Parses lock file text: the YAML block style `cocoon.lock` uses (the
  /// shape `cocoon_generator migrate` writes), or the JSON shape older
  /// projects committed as `cocoon.lock.json`. Both restore the same lock,
  /// so the same lock read either way carries the same fingerprint.
  factory SchemaLock.parse(String source) => parseLockText(source);

  /// Schema version; bumped once per generated migration.
  final int version;

  /// Collections keyed by model name.
  final Map<String, CollectionSpec> collections;

  /// Embedded classes keyed by type name.
  final Map<String, EmbeddedSpec> embedded;

  /// The lock file's JSON shape for the whole lock.
  Map<String, Object> toJson() {
    final models = collections.keys.toList()..sort();
    final json = <String, Object>{
      'format': schemaLockFormat,
      'version': version,
      'collections': {for (final m in models) m: collections[m]!.toJson()},
    };
    if (embedded.isNotEmpty) {
      final names = embedded.keys.toList()..sort();
      json['embedded'] = {for (final n in names) n: embedded[n]!.toJson()};
    }
    return json;
  }

  /// Deterministic, diff-friendly lock file text.
  String toSource() =>
      '${const JsonEncoder.withIndent('  ').convert(toJson())}\n';
}

/// A field whose stored value must be converted by a migration step: its type
/// changed (possibly together with a rename), so it moved to a new number.
@immutable
class FieldUpgrade {
  /// The old pin [from] and the new pin [to] (a fresh number).
  const FieldUpgrade({required this.from, required this.to});

  /// The field as the old lock pinned it.
  final FieldSpec from;

  /// The field as the new lock pins it.
  final FieldSpec to;

  @override
  bool operator ==(Object other) =>
      other is FieldUpgrade && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);

  @override
  String toString() => '$from -> $to';
}

/// A possible rename suggested for a removed field.
@immutable
class RenameCandidate {
  /// Suggests renaming [from] (the removed lock field) to [to], ranked by
  /// [similarity].
  const RenameCandidate({
    required this.from,
    required this.to,
    required this.similarity,
  });

  /// The removed lock field.
  final FieldSpec from;

  /// The model field that may replace it.
  final DeclaredField to;

  /// Name similarity from 0 to 1 (case-insensitive edit distance).
  final double similarity;

  /// Same type means a rename keeps the data untouched.
  bool get sameType => from.type == to.type;

  @override
  String toString() =>
      '${from.name} -> ${to.name} (${similarity.toStringAsFixed(2)})';
}

/// How one model differs from its pinned lock entry.
@immutable
class CollectionDiff {
  CollectionDiff._(
    this.declared,
    this.previous,
    this.kept,
    this.typeChanged,
    this.removed,
    this.added,
  );

  /// Diffs the model [declared] against the lock entry [previous] (null
  /// when the model is new), classifying every field as kept, type-changed,
  /// removed or added.
  factory CollectionDiff.compute(
    CollectionSpec? previous,
    DeclaredCollection declared,
  ) {
    _validateDeclared(declared);
    final (
      kept: kept,
      typeChanged: typeChanged,
      removed: removed,
      added: added,
    ) = _diffFields(
      previous?.fields,
      declared.fields,
    );
    return CollectionDiff._(
      declared,
      previous,
      List.unmodifiable(kept),
      List.unmodifiable(typeChanged),
      List.unmodifiable(removed),
      List.unmodifiable(added),
    );
  }

  /// The model as the code declares it.
  final DeclaredCollection declared;

  /// The lock entry, or `null` for a brand-new collection.
  final CollectionSpec? previous;

  /// Fields matched by name with the same type: untouched.
  final List<FieldSpec> kept;

  /// Fields matched by name whose type changed: they need an upgrade step.
  final List<(FieldSpec, DeclaredField)> typeChanged;

  /// Lock fields missing from the model: renamed or dropped, ask the user.
  final List<FieldSpec> removed;

  /// Model fields missing from the lock: renamed or new, ask the user.
  final List<DeclaredField> added;

  /// Whether the model is new (no lock entry yet): nothing to ask, just
  /// assign fresh numbers.
  bool get isNew => previous == null;

  /// Whether the model moved to a different collection path, which the
  /// migrate command refuses.
  bool get pathChanged => previous != null && previous!.path != declared.path;

  /// Whether the `Index([...])` set changed: the on-device open creates or
  /// drops the SQLite indexes, so the schema version moves with it.
  ///
  /// The comparison ignores the declaration ORDER of the indexes: an index's
  /// physical identity is its canonical definition, not its position in the
  /// annotation, so moving a one-field `Index([...])` to `@Indexed()` on the
  /// field (or reordering the list) declares the same indexes and changes
  /// nothing.
  bool get indexesChanged {
    final previousIndexes = previous?.indexes;
    if (previousIndexes == null) {
      return true;
    }
    String sortedText(List<List<String>> indexes) {
      final parts = [for (final index in indexes) index.join(',')];
      parts.sort();
      return parts.join('|');
    }

    return sortedText(previousIndexes) != sortedText(declared.indexes);
  }

  /// Whether the `@Mirrored()` set changed: the on-device open adds and
  /// backfills, or drops, the mirrored `f_` columns, so the schema version
  /// moves with it exactly like an index change.
  bool get mirroredChanged =>
      previous == null ||
      jsonEncode(previous!.mirrored) != jsonEncode(declared.mirrored);

  /// Whether the generator has to ask before it can resolve this diff:
  /// something was removed while something else appeared.
  bool get needsRenameDecisions =>
      !isNew && removed.isNotEmpty && added.isNotEmpty;

  /// Whether models and lock already agree for this collection: nothing to
  /// ask, nothing to migrate.
  bool get isEmpty =>
      !isNew &&
      typeChanged.isEmpty &&
      removed.isEmpty &&
      added.isEmpty &&
      !pathChanged &&
      !indexesChanged &&
      !mirroredChanged;

  /// Rename suggestions for [field], best first: same type, then most similar
  /// name. `staffId` -> `staffUid` ranks high; the CLI preselects the top one.
  List<RenameCandidate> candidatesFor(FieldSpec field) {
    if (!removed.contains(field)) {
      throw ArgumentError.value(field.name, 'field', 'Not a removed field');
    }
    final candidates = [
      for (final to in added)
        RenameCandidate(
          from: field,
          to: to,
          similarity: nameSimilarity(field.name, to.name),
        ),
    ];
    candidates.sort((a, b) {
      if (a.sameType != b.sameType) return a.sameType ? -1 : 1;
      return b.similarity.compareTo(a.similarity);
    });
    return candidates;
  }

  /// Resolves the diff into the new lock entry.
  ///
  /// [renames] maps removed field names to added field names. Every removed
  /// field not in [renames] is dropped and its number reserved. Every added
  /// field not targeted by a rename gets a fresh number.
  ///
  /// [keepZeroFields] names added fields the developer decided to keep at
  /// their proto3 zero value instead of backfilling; they are recorded in
  /// the new spec's [CollectionSpec.keepZero]. The record also carries
  /// forward for every field that was kept unchanged (same name, type and
  /// number), and is forgotten for everything else — a dropped or
  /// type-changed field would come back as a new number, which is a new
  /// decision.
  ({CollectionSpec spec, List<FieldUpgrade> upgrades}) resolve({
    Map<String, String> renames = const {},
    Set<String> keepZeroFields = const {},
  }) {
    final removedByName = {for (final f in removed) f.name: f};
    final addedNames = {for (final f in added) f.name};
    final renamedFrom = <String, FieldSpec>{};
    for (final MapEntry(key: from, value: to) in renames.entries) {
      final old = removedByName[from];
      if (old == null) {
        throw ArgumentError(
          'Cannot rename "$from": it is not a removed field of ${declared.model}',
        );
      }
      if (!addedNames.contains(to)) {
        throw ArgumentError(
          'Cannot rename to "$to": it is not a new field of ${declared.model}',
        );
      }
      if (renamedFrom.containsKey(to)) {
        throw ArgumentError('Two fields renamed to "$to" in ${declared.model}');
      }
      renamedFrom[to] = old;
    }

    final reserved = {...?previous?.reserved};
    var next = previous?.nextNumber ?? 1;
    final fields = <FieldSpec>[];
    final upgrades = <FieldUpgrade>[];
    final previousKeepZero = previous?.keepZero ?? const <String>[];
    final newKeepZero = <String>{};

    for (final field in declared.fields) {
      final kept = previous?.field(field.name);
      final renamed = renamedFrom[field.name];
      final old = kept ?? renamed;
      if (old != null && old.type == field.type) {
        fields.add(
          FieldSpec(name: field.name, number: old.number, type: field.type),
        );
        if (kept != null && previousKeepZero.contains(field.name)) {
          newKeepZero.add(field.name);
        }
      } else {
        final spec = FieldSpec(
          name: field.name,
          number: next++,
          type: field.type,
        );
        fields.add(spec);
        if (old != null) {
          reserved.add(old.number);
          upgrades.add(FieldUpgrade(from: old, to: spec));
        } else if (keepZeroFields.contains(field.name)) {
          newKeepZero.add(field.name);
        }
      }
    }
    final renamedNumbers = {for (final f in renamedFrom.values) f.number};
    for (final f in removed) {
      if (!renamedNumbers.contains(f.number)) reserved.add(f.number);
    }

    return (
      spec: CollectionSpec(
        model: declared.model,
        path: declared.path,
        fields: fields,
        reserved: reserved,
        indexes: declared.indexes,
        mirrored: declared.mirrored,
        keepZero: newKeepZero.toList(),
      ),
      upgrades: List.unmodifiable(upgrades),
    );
  }

  static void _validateDeclared(DeclaredCollection declared) {
    final pattern = CollectionPattern.parse(declared.path);
    final names = <String>{};
    for (final f in declared.fields) {
      if (!names.add(f.name)) {
        throw ArgumentError('Duplicate field "${f.name}" in ${declared.model}');
      }
      if (pattern.params.contains(f.name)) {
        throw ArgumentError(
          'Field "${f.name}" in ${declared.model} shadows the path param {${f.name}}',
        );
      }
    }
    final indexable = {...names, ...pattern.params};
    final typesByName = {for (final f in declared.fields) f.name: f.type};
    for (final index in declared.indexes) {
      if (index.isEmpty) {
        throw ArgumentError('Empty index in ${declared.model}');
      }
      for (final entry in index) {
        final name = entry.startsWith('-') ? entry.substring(1) : entry;
        if (!indexable.contains(name)) {
          throw ArgumentError(
            'Index on unknown field "$name" in ${declared.model}',
          );
        }
        if (typesByName[name]?.startsWith('Map<') ?? false) {
          throw ArgumentError(
            'Field "$name" of ${declared.model} cannot be indexed: Map '
            'fields are stored inside the document blob and have no column',
          );
        }
      }
    }
    for (final name in declared.mirrored) {
      if (!indexable.contains(name)) {
        throw ArgumentError(
          '@Mirrored on unknown field "$name" in ${declared.model}',
        );
      }
      if (typesByName[name]?.startsWith('Map<') ?? false) {
        throw ArgumentError(
          'Field "$name" of ${declared.model} cannot be mirrored: Map fields '
          'are stored inside the document blob and have no column',
        );
      }
    }
  }
}

/// The matched, changed, removed and added fields of two field lists: the
/// shared core of [CollectionDiff] and [EmbeddedDiff].
({
  List<FieldSpec> kept,
  List<(FieldSpec, DeclaredField)> typeChanged,
  List<FieldSpec> removed,
  List<DeclaredField> added,
})
_diffFields(
  List<FieldSpec>? previousFields,
  List<DeclaredField> declaredFields,
) {
  final kept = <FieldSpec>[];
  final typeChanged = <(FieldSpec, DeclaredField)>[];
  final added = <DeclaredField>[];
  for (final field in declaredFields) {
    final old = previousFields?.where((f) => f.name == field.name).firstOrNull;
    if (old == null) {
      added.add(field);
    } else if (old.type == field.type) {
      kept.add(old);
    } else {
      typeChanged.add((old, field));
    }
  }
  final declaredNames = {for (final f in declaredFields) f.name};
  final removed = [
    for (final f in previousFields ?? const <FieldSpec>[])
      if (!declaredNames.contains(f.name)) f,
  ];
  return (kept: kept, typeChanged: typeChanged, removed: removed, added: added);
}

/// How one embedded class differs from its pinned lock entry.
///
/// The same semantics as [CollectionDiff], without path or indexes: embedded
/// classes are stored inline and never queried directly.
@immutable
class EmbeddedDiff {
  EmbeddedDiff._(
    this.declared,
    this.previous,
    this.kept,
    this.typeChanged,
    this.removed,
    this.added,
  );

  /// Diffs the embedded class [declared] against the lock entry [previous]
  /// (null when the class is new), classifying every field like
  /// [CollectionDiff.compute].
  factory EmbeddedDiff.compute(
    EmbeddedSpec? previous,
    DeclaredEmbedded declared,
  ) {
    final (
      kept: kept,
      typeChanged: typeChanged,
      removed: removed,
      added: added,
    ) = _diffFields(
      previous?.fields,
      declared.fields,
    );
    return EmbeddedDiff._(
      declared,
      previous,
      List.unmodifiable(kept),
      List.unmodifiable(typeChanged),
      List.unmodifiable(removed),
      List.unmodifiable(added),
    );
  }

  /// The class as the code declares it.
  final DeclaredEmbedded declared;

  /// The lock entry, or `null` for a brand-new embedded class.
  final EmbeddedSpec? previous;

  /// Fields matched by name with the same type: untouched.
  final List<FieldSpec> kept;

  /// Fields matched by name whose type changed: they need an upgrade step.
  final List<(FieldSpec, DeclaredField)> typeChanged;

  /// Lock fields missing from the class: renamed or dropped, ask the user.
  final List<FieldSpec> removed;

  /// Class fields missing from the lock: renamed or new, ask the user.
  final List<DeclaredField> added;

  /// Whether the class is new (no lock entry yet): nothing to ask, just
  /// assign fresh numbers.
  bool get isNew => previous == null;

  /// Whether the generator has to ask before it can resolve this diff:
  /// something was removed while something else appeared.
  bool get needsRenameDecisions =>
      !isNew && removed.isNotEmpty && added.isNotEmpty;

  /// Whether models and lock already agree for this class: nothing to ask,
  /// nothing to migrate.
  bool get isEmpty =>
      !isNew && typeChanged.isEmpty && removed.isEmpty && added.isEmpty;

  /// Rename suggestions for [field], best first: same type, then most similar
  /// name. Same semantics as [CollectionDiff.candidatesFor].
  List<RenameCandidate> candidatesFor(FieldSpec field) {
    if (!removed.contains(field)) {
      throw ArgumentError.value(field.name, 'field', 'Not a removed field');
    }
    final candidates = [
      for (final to in added)
        RenameCandidate(
          from: field,
          to: to,
          similarity: nameSimilarity(field.name, to.name),
        ),
    ];
    candidates.sort((a, b) {
      if (a.sameType != b.sameType) return a.sameType ? -1 : 1;
      return b.similarity.compareTo(a.similarity);
    });
    return candidates;
  }

  /// Resolves the diff into the new lock entry. Same semantics as
  /// [CollectionDiff.resolve]: [renames] maps removed field names to added
  /// field names; drops reserve their numbers.
  ({EmbeddedSpec spec, List<FieldUpgrade> upgrades}) resolve({
    Map<String, String> renames = const {},
  }) {
    final removedByName = {for (final f in removed) f.name: f};
    final addedNames = {for (final f in added) f.name};
    final renamedFrom = <String, FieldSpec>{};
    for (final MapEntry(key: from, value: to) in renames.entries) {
      final old = removedByName[from];
      if (old == null) {
        throw ArgumentError(
          'Cannot rename "$from": it is not a removed field of ${declared.name}',
        );
      }
      if (!addedNames.contains(to)) {
        throw ArgumentError(
          'Cannot rename to "$to": it is not a new field of ${declared.name}',
        );
      }
      if (renamedFrom.containsKey(to)) {
        throw ArgumentError('Two fields renamed to "$to" in ${declared.name}');
      }
      renamedFrom[to] = old;
    }

    final reserved = {...?previous?.reserved};
    var next = previous?.nextNumber ?? 1;
    final fields = <FieldSpec>[];
    final upgrades = <FieldUpgrade>[];

    for (final field in declared.fields) {
      final kept = previous?.field(field.name);
      final renamed = renamedFrom[field.name];
      final old = kept ?? renamed;
      if (old != null && old.type == field.type) {
        fields.add(
          FieldSpec(name: field.name, number: old.number, type: field.type),
        );
      } else {
        final spec = FieldSpec(
          name: field.name,
          number: next++,
          type: field.type,
        );
        fields.add(spec);
        if (old != null) {
          reserved.add(old.number);
          upgrades.add(FieldUpgrade(from: old, to: spec));
        }
      }
    }
    final renamedNumbers = {for (final f in renamedFrom.values) f.number};
    for (final f in removed) {
      if (!renamedNumbers.contains(f.number)) reserved.add(f.number);
    }

    return (
      spec: EmbeddedSpec(
        name: declared.name,
        fields: fields,
        reserved: reserved,
      ),
      upgrades: List.unmodifiable(upgrades),
    );
  }
}

/// The difference between the committed lock and the current models.
@immutable
class SchemaDiff {
  SchemaDiff._withEmbedded(
    this.lock,
    this.collections,
    this.removedCollections,
    this.embedded,
  );

  /// Diffs every collection in [declared] (and the embedded classes in
  /// [declaredEmbedded]) against the committed [lock].
  factory SchemaDiff.compute(
    SchemaLock lock,
    List<DeclaredCollection> declared, [
    List<DeclaredEmbedded> declaredEmbedded = const [],
  ]) {
    final models = <String>{};
    for (final c in declared) {
      if (!models.add(c.model)) {
        throw ArgumentError('Model ${c.model} is declared twice');
      }
    }
    final paths = <String>{};
    for (final c in declared) {
      if (!paths.add(c.path)) {
        throw ArgumentError('Two models use the collection path ${c.path}');
      }
    }
    final embeddedNames = <String>{};
    for (final e in declaredEmbedded) {
      if (!embeddedNames.add(e.name)) {
        throw ArgumentError('Embedded class ${e.name} is declared twice');
      }
    }
    return SchemaDiff._withEmbedded(
      lock,
      List.unmodifiable([
        for (final c in declared)
          CollectionDiff.compute(lock.collections[c.model], c),
      ]),
      List.unmodifiable([
        for (final e in lock.collections.entries)
          if (!models.contains(e.key)) e.value,
      ]),
      List.unmodifiable([
        for (final e in declaredEmbedded)
          EmbeddedDiff.compute(lock.embedded[e.name], e),
      ]),
    );
  }

  /// The committed lock the models were diffed against.
  final SchemaLock lock;

  /// Every declared collection, diffed against its lock entry.
  final List<CollectionDiff> collections;

  /// Lock collections with no model anymore: dropped (the CLI confirms).
  final List<CollectionSpec> removedCollections;

  /// Embedded classes referenced by the models, diffed against the lock.
  final List<EmbeddedDiff> embedded;

  /// Whether models and lock already agree. build_runner fails when this is
  /// false, telling the developer to run `cocoon migrate`.
  bool get isEmpty =>
      removedCollections.isEmpty &&
      collections.every((c) => c.isEmpty) &&
      embedded.every((e) => e.isEmpty);

  /// Resolves every collection into the next lock.
  ///
  /// [renames] is keyed by model name, then removed field name -> new name;
  /// [embeddedRenames] the same, keyed by embedded class name;
  /// [keepZeroFields] is keyed by model name and names that model's added
  /// fields to record at their zero value (see
  /// [CollectionDiff.resolve]). Embedded classes not declared anymore are
  /// dropped. The version bumps only when something changed.
  ({SchemaLock lock, Map<String, List<FieldUpgrade>> upgrades}) resolve({
    Map<String, Map<String, String>> renames = const {},
    Map<String, Map<String, String>> embeddedRenames = const {},
    Map<String, Set<String>> keepZeroFields = const {},
  }) {
    final unknown = [
      ...renames.keys.where(
        (m) => !collections.any((c) => c.declared.model == m),
      ),
      ...keepZeroFields.keys.where(
        (m) => !collections.any((c) => c.declared.model == m),
      ),
    ];
    if (unknown.isNotEmpty) {
      throw ArgumentError('Renames for unknown models: ${unknown.join(', ')}');
    }
    final specs = <String, CollectionSpec>{};
    final upgrades = <String, List<FieldUpgrade>>{};
    for (final diff in collections) {
      final model = diff.declared.model;
      final resolved = diff.resolve(
        renames: renames[model] ?? const {},
        keepZeroFields: keepZeroFields[model] ?? const {},
      );
      specs[model] = resolved.spec;
      if (resolved.upgrades.isNotEmpty) upgrades[model] = resolved.upgrades;
    }
    final embeddedSpecs = <String, EmbeddedSpec>{};
    for (final diff in embedded) {
      final name = diff.declared.name;
      final resolved = diff.resolve(renames: embeddedRenames[name] ?? const {});
      embeddedSpecs[name] = resolved.spec;
      if (resolved.upgrades.isNotEmpty) {
        if (upgrades.containsKey(name)) {
          throw ArgumentError('Model and embedded class are both named $name');
        }
        upgrades[name] = resolved.upgrades;
      }
    }
    return (
      lock: SchemaLock(
        version: isEmpty ? lock.version : lock.version + 1,
        collections: specs,
        embedded: embeddedSpecs,
      ),
      upgrades: Map.unmodifiable(upgrades),
    );
  }
}

/// Case-insensitive name similarity from 0 (unrelated) to 1 (equal), based on
/// Levenshtein edit distance.
double nameSimilarity(String a, String b) {
  final x = a.toLowerCase();
  final y = b.toLowerCase();
  if (x == y) return 1;
  final longest = math.max(x.length, y.length);
  if (longest == 0) return 1;
  var previous = List<int>.generate(y.length + 1, (i) => i);
  for (var i = 1; i <= x.length; i++) {
    final current = List<int>.filled(y.length + 1, 0)..[0] = i;
    for (var j = 1; j <= y.length; j++) {
      final cost = x.codeUnitAt(i - 1) == y.codeUnitAt(j - 1) ? 0 : 1;
      current[j] = math.min(
        math.min(current[j - 1] + 1, previous[j] + 1),
        previous[j - 1] + cost,
      );
    }
    previous = current;
  }
  return 1 - previous[y.length] / longest;
}
