/// The `dart run cocoon_generator:migrate` command.
///
/// Diffs the models of the current package against its committed
/// `cocoon.lock` (falling back to the retired `cocoon.lock.json`), asks the
/// developer only the questions a human must answer — which removed field
/// was renamed to which new one, and whether a field or collection is
/// really dropped — and writes the new lock plus, only when stored data
/// must change, a numbered migration file under `lib/cocoon_migrations/`.
///
/// The whole flow is injectable for tests: [runMigrate] takes the package
/// root, the argv and a [MigrateIo] (a fake terminal), and returns the
/// process exit code.
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:cocoon/cocoon.dart';
import 'package:source_gen/source_gen.dart';

import 'extract.dart';
import 'lock_yaml.dart';

/// Exit code 1: refused, `--check` would change, or the run was aborted.
const _exitAborted = 1;

/// Exit code 2: usage error or a missing decision on non-interactive stdin.
const _exitUsage = 2;

/// A failure the migrate command reports to the user.
final class MigrateException implements Exception {
  /// Builds a failure with the process exit code it maps to.
  MigrateException(this.message, {this.exitCode = _exitAborted});

  /// The message printed (in red, when stdout is a terminal).
  final String message;

  /// The process exit code: 1 for refusals and aborts, 2 for usage errors
  /// and missing decisions on non-interactive stdin.
  final int exitCode;

  @override
  String toString() => message;
}

/// Where the command reads answers from and writes output to.
///
/// The real implementation talks to `stdin`/`stdout`; tests inject a fake
/// terminal.
abstract interface class MigrateIo {
  /// Whether stdin is a terminal. When it is not, no prompt is shown and a
  /// missing decision exits 2.
  bool get stdinIsTerminal;

  /// Whether stdout is a terminal (colors are used only then).
  bool get stdoutIsTerminal;

  /// Reads one answer line (without the trailing newline). An exhausted
  /// input yields `''`, which always means "the default answer".
  String readLine();

  /// Writes output (prompts, menus, results). Callers include newlines.
  void write(String text);

  /// Writes a diagnostic note to stderr (fallback notices that are not part
  /// of the command's result output).
  void writeError(String text);
}

final class _StdMigrateIo implements MigrateIo {
  @override
  bool get stdinIsTerminal => stdin.hasTerminal;

  @override
  bool get stdoutIsTerminal => stdout.hasTerminal;

  @override
  String readLine() => stdin.readLineSync() ?? '';

  @override
  void write(String text) => stdout.write(text);

  @override
  void writeError(String text) => stderr.write(text);
}

/// The parsed command line.
final class _Options {
  const _Options({
    required this.renames,
    required this.drops,
    required this.dropCollections,
    required this.backfills,
    required this.keepZeros,
    required this.yes,
    required this.check,
  });

  /// `--rename Model.old=new`: model, old field name, new field name.
  final List<(String, String, String)> renames;

  /// `--drop Model.field`: explicit drops.
  final List<(String, String)> drops;

  /// `--drop-collection Model` (also accepted for removed embedded classes).
  final List<String> dropCollections;

  /// `--backfill Model.field`: decide an added required field with a
  /// backfill stub (the default answer).
  final List<(String, String)> backfills;

  /// `--keep-zero Model.field`: decide an added required field to keep the
  /// proto3 zero value, recorded in the lock.
  final List<(String, String)> keepZeros;

  /// `--yes`: accept the default answer of every rename menu and of every
  /// new-required-field question (a backfill stub — never "keep zero").
  /// Drop confirmations are never covered: drops must be explicit flags.
  final bool yes;

  /// `--check`: exit 1 when the lock would change (a pending
  /// `cocoon.lock.json` -> `cocoon.lock` conversion included); never writes.
  final bool check;
}

/// Runs the migrate command over the package containing [packageRoot]
/// (default: the working directory, walking up to the nearest
/// `pubspec.yaml`). Returns the process exit code.
///
/// Exit codes: 0 when up to date or written; 1 when `--check` would change
/// something or the run was refused/aborted; 2 for usage errors and missing
/// decisions on non-interactive stdin.
Future<int> runMigrate({
  String? packageRoot,
  List<String> args = const [],
  MigrateIo? io,
}) async {
  final terminal = io ?? _StdMigrateIo();
  String? failure;
  var failureExit = _exitAborted;
  try {
    return await _run(packageRoot, args, terminal);
  } on MigrateException catch (error) {
    failure = error.message;
    failureExit = error.exitCode;
  } on CocoonBuildError catch (error, stack) {
    failure = error.message;
    assert(() {
      stdout.writeln(stack);
      return true;
    }());
  } on ArgumentError catch (error, stack) {
    failure = error.message?.toString() ?? error.toString();
    assert(() {
      stdout.writeln(stack);
      return true;
    }());
  } on FormatException catch (error) {
    failure = error.message;
  }
  final message = failure;
  terminal
    ..write(_color(message, _ansiRed, terminal.stdoutIsTerminal))
    ..write('\n');
  return failureExit;
}

Future<int> _run(String? packageRoot, List<String> args, MigrateIo io) async {
  final options = _parseArgs(args);
  final root = findPackageRoot(packageRoot);
  final libPath = '$root/lib';
  if (!Directory(libPath).existsSync()) {
    throw MigrateException(
      'No lib/ directory under $root.',
      exitCode: _exitUsage,
    );
  }

  final (:models, :embedded, :classes, :modelLibraries) =
      await _extractDeclarations(libPath);
  final lockYamlFile = File('$root/$lockFileName');
  final legacyJsonFile = File('$root/$legacyLockFileName');
  if (lockYamlFile.existsSync() && legacyJsonFile.existsSync()) {
    throw MigrateException(
      'Both $lockFileName and $legacyLockFileName exist in $root. Delete '
      'one of them — migrate maintains $lockFileName; '
      '$legacyLockFileName is the retired JSON name — and run again.',
    );
  }
  final hasLegacyJson = legacyJsonFile.existsSync();
  if (hasLegacyJson) {
    io.writeError(
      'Note: no $lockFileName found; reading the legacy '
      '$legacyLockFileName. This run converts it to $lockFileName.\n',
    );
  }
  final lock = lockYamlFile.existsSync()
      ? parseLockYaml(lockYamlFile.readAsStringSync())
      : hasLegacyJson
      ? SchemaLock.parse(legacyJsonFile.readAsStringSync())
      : SchemaLock.empty();
  final convertLockFile = hasLegacyJson;
  final diff = SchemaDiff.compute(
    lock,
    [for (final model in models) model.declared],
    [for (final e in embedded) e.declared],
  );

  if (diff.isEmpty && !convertLockFile) {
    io.write(
      '${_color('Schema is up to date (version ${lock.version}).', _ansiGreen, io.stdoutIsTerminal)}\n',
    );
    return 0;
  }
  for (final collection in diff.collections) {
    if (!collection.pathChanged) {
      continue;
    }
    throw MigrateException(
      'Cannot move ${collection.declared.model}: its collection path changed '
      'from "${collection.previous!.path}" to "${collection.declared.path}". '
      'Moving a collection is not supported: delete its documents and store '
      'them under a new collection instead.',
    );
  }
  if (options.check) {
    if (!diff.isEmpty) {
      io.write(_describeChanges(diff));
      final pending = _pendingRequiredFields(diff, classes);
      if (pending.isNotEmpty) {
        io.write('New required fields need a decision:\n');
        for (final (collection, field) in pending) {
          io.write('  - ${_requiredFieldLine(collection, field)}\n');
        }
      }
    }
    if (convertLockFile) {
      io.write(
        'The lock file would change: $legacyLockFileName would be converted '
        'to $lockFileName'
        '${diff.isEmpty ? ' (schema version ${lock.version} is unchanged)' : ''}'
        '.\n',
      );
    }
    io.write(
      '${_color('$lockFileName was not written (--check).', _ansiYellow, io.stdoutIsTerminal)}\n',
    );
    return _exitAborted;
  }

  final removedEmbedded = [
    for (final name in lock.embedded.keys)
      if (!diff.embedded.any((e) => e.declared.name == name)) name,
  ]..sort();

  final decisions = _decide(diff, removedEmbedded, options, io, classes);

  final (lock: newLock, upgrades: upgrades) = diff.resolve(
    renames: decisions.collections,
    embeddedRenames: decisions.embedded,
    keepZeroFields: decisions.keepZero,
  );
  // Refuse before anything is written: a type the command cannot generate a
  // conversion for (lists, embedded classes, maps whose values are lists or
  // embedded classes) must not leave a half-migrated lock behind — the build
  // would pass against it while stored documents keep the old numbers.
  for (final model in upgrades.keys) {
    for (final upgrade in upgrades[model]!) {
      final context = '$model.${upgrade.from.name}';
      _stubType(upgrade.from.type, context);
      _stubType(upgrade.to.type, context);
      _wireTypeOf(upgrade.from.type, context);
      _wireTypeOf(upgrade.to.type, context);
    }
  }
  for (final model in decisions.backfills.keys) {
    for (final field in decisions.backfills[model]!) {
      final type = _declaredFieldType(diff, model, field);
      _wireTypeOf(type, '$model.$field');
    }
  }
  _writeLockFile(root, newLock, convertLockFile, io);

  if (upgrades.isNotEmpty || decisions.backfills.isNotEmpty) {
    _writeMigrationFile(
      root,
      newLock.version,
      upgrades,
      decisions.backfills,
      newLock,
      modelLibraries,
      io,
    );
    io.write(
      'Next: implement the `upgrade...` and `backfill...` functions in the '
      'new migration file, then run build_runner.\n',
    );
  }
  _writeMigrationsList(root, io);
  return 0;
}

// -- Extraction -------------------------------------------------------------

typedef _Declarations = ({
  List<ExtractedModel> models,
  List<ExtractedEmbedded> embedded,

  /// The extracted classes keyed by name: the constructor defaults decide
  /// whether an added field needs a value for old documents.
  Map<String, ExtractedClass> classes,

  /// The declaring library URI (e.g. `package:app/models.dart`) per model
  /// name: the import a backfill stub file needs for the model type.
  Map<String, String> modelLibraries,
});

Future<_Declarations> _extractDeclarations(String libPath) async {
  final contexts = AnalysisContextCollection(includedPaths: [libPath]);
  final models = <ExtractedModel>[];
  final embedded = <ExtractedEmbedded>[];
  final classes = <String, ExtractedClass>{};
  final modelLibraries = <String, String>{};
  final modelNames = <String>{};
  final embeddedNames = <String>{};
  for (final context in contexts.contexts) {
    for (final filePath in context.contextRoot.analyzedFiles()) {
      if (!filePath.endsWith('.dart')) {
        continue;
      }
      final result = await context.currentSession.getResolvedLibrary(filePath);
      if (result is! ResolvedLibraryResult) {
        continue;
      }
      final declarations = extractLibrary(LibraryReader(result.element));
      if (declarations == null) {
        continue;
      }
      final libraryUri = result.element.identifier;
      for (final model in declarations.models) {
        if (!modelNames.add(model.clazz.name)) {
          throw MigrateException(
            'Model ${model.clazz.name} is declared in more than one library '
            'under lib/; one name must be one collection.',
          );
        }
        models.add(model);
        classes[model.clazz.name] = model.clazz;
        modelLibraries[model.clazz.name] = libraryUri;
      }
      for (final embeddedClass in declarations.embedded) {
        if (embeddedNames.add(embeddedClass.clazz.name)) {
          embedded.add(embeddedClass);
          classes[embeddedClass.clazz.name] = embeddedClass.clazz;
        }
      }
    }
  }
  return (
    models: models,
    embedded: embedded,
    classes: classes,
    modelLibraries: modelLibraries,
  );
}

// -- Decisions ----------------------------------------------------------------

/// The decisions of one migrate run, split the way `SchemaDiff.resolve` and
/// the migration-file writer take them.
typedef _Decisions = ({
  Map<String, Map<String, String>> collections,
  Map<String, Map<String, String>> embedded,

  /// Added fields decided "backfill", per model: the new migration file
  /// carries one stub per field.
  Map<String, Set<String>> backfills,

  /// Added fields decided "keep the zero value", per model: recorded in the
  /// new lock so the question is never asked again.
  Map<String, Set<String>> keepZero,
});

/// Works out every decision before resolving: flags first (validated
/// against the diff), then prompts for the rest. On non-interactive stdin a
/// missing decision throws with the flags that would resolve it; a `No` at
/// any drop confirmation aborts without writing.
_Decisions _decide(
  SchemaDiff diff,
  List<String> removedEmbedded,
  _Options options,
  MigrateIo io,
  Map<String, ExtractedClass> classes,
) {
  final renames = <String, Map<String, String>>{};
  final embeddedRenames = <String, Map<String, String>>{};
  final decidedFields = <String, Set<String>>{};
  final droppedNames = <String>{};
  final backfilled = <String, Set<String>>{};
  final keepZero = <String, Set<String>>{};

  void decideFlagTarget({
    required String model,
    required String old,
    required String newName,
  }) {
    final (collection, embeddedClass) = _diffFor(diff, model);
    final removed = (collection?.removed ?? embeddedClass!.removed)
        .where((f) => f.name == old)
        .firstOrNull;
    if (removed == null) {
      throw MigrateException(
        '--rename $model.$old: "$old" is not a removed field of $model.',
        exitCode: _exitUsage,
      );
    }
    final added = (collection?.added ?? embeddedClass!.added).where(
      (f) => f.name == newName,
    );
    if (added.isEmpty) {
      throw MigrateException(
        '--rename $model.$old=$newName: "$newName" is not a new field of '
        '$model.',
        exitCode: _exitUsage,
      );
    }
    final map = collection != null
        ? renames.putIfAbsent(model, () => {})
        : embeddedRenames.putIfAbsent(model, () => {});
    if (map.containsKey(old)) {
      throw MigrateException(
        '--rename $model.$old: given twice.',
        exitCode: _exitUsage,
      );
    }
    map[old] = newName;
    decidedFields.putIfAbsent(model, () => {}).add(old);
  }

  for (final (model, old, newName) in options.renames) {
    if (_diffFor(diff, model) == (null, null)) {
      throw MigrateException(
        '--rename $model.$old=$newName: no model or embedded class "$model" '
        'has changed.',
        exitCode: _exitUsage,
      );
    }
    decideFlagTarget(model: model, old: old, newName: newName);
  }

  // The --backfill / --keep-zero flags decide an added required field up
  // front; both share the same validation and are mutually exclusive per
  // field, like two --rename flags for the same removed field.
  void decideFlagAdded({
    required String model,
    required String field,
    required bool backfill,
  }) {
    final flag = backfill ? '--backfill' : '--keep-zero';
    final collection = diff.collections
        .where((c) => c.declared.model == model)
        .firstOrNull;
    if (collection == null) {
      final embeddedClass = diff.embedded
          .where((e) => e.declared.name == model)
          .firstOrNull;
      throw MigrateException(
        '$flag $model.$field: ${embeddedClass == null ? '"$field" is not a new field of $model.' : '$model is an embedded class; its fields are not backfilled — '
                  'make $model.$field nullable or give it a constructor '
                  'default instead.'}',
        exitCode: _exitUsage,
      );
    }
    if (collection.isNew) {
      throw MigrateException(
        '$flag $model.$field: $model is a new collection; it has no existing '
        'documents to backfill.',
        exitCode: _exitUsage,
      );
    }
    final added = collection.added.where((f) => f.name == field).firstOrNull;
    if (added == null) {
      throw MigrateException(
        '$flag $model.$field: "$field" is not a new field of $model.',
        exitCode: _exitUsage,
      );
    }
    if (added.type.endsWith('?')) {
      throw MigrateException(
        '$flag $model.$field: the field is nullable; old documents read null '
        'and there is nothing to decide.',
        exitCode: _exitUsage,
      );
    }
    if (classes[model]?.defaults.containsKey(field) ?? false) {
      throw MigrateException(
        '$flag $model.$field: the field has a constructor default; old '
        'documents read it and there is nothing to decide.',
        exitCode: _exitUsage,
      );
    }
    if (!_isStorableScalar(added.type)) {
      throw MigrateException(
        '$flag $model.$field: ${added.type} fields read an empty value on '
        'old documents and are not backfilled.',
        exitCode: _exitUsage,
      );
    }
    if (renames[model]?.containsValue(field) ?? false) {
      throw MigrateException(
        '$flag $model.$field: "$field" is decided by a rename; remove the '
        '--rename that targets it.',
        exitCode: _exitUsage,
      );
    }
    if (backfilled[model]?.contains(field) ??
        keepZero[model]?.contains(field) ??
        false) {
      throw MigrateException(
        '$flag $model.$field: given twice.',
        exitCode: _exitUsage,
      );
    }
    (backfill ? backfilled : keepZero).putIfAbsent(model, () => {}).add(field);
  }

  for (final (model, field) in options.backfills) {
    decideFlagAdded(model: model, field: field, backfill: true);
  }
  for (final (model, field) in options.keepZeros) {
    decideFlagAdded(model: model, field: field, backfill: false);
  }
  for (final (model, field) in options.drops) {
    final (collection, embeddedClass) = _diffFor(diff, model);
    final removed = (collection?.removed ?? embeddedClass?.removed ?? const [])
        .where((f) => f.name == field);
    if (collection == null && embeddedClass == null) {
      throw MigrateException(
        '--drop $model.$field: no model or embedded class "$model" has '
        'changed.',
        exitCode: _exitUsage,
      );
    }
    if (removed.isEmpty) {
      throw MigrateException(
        '--drop $model.$field: "$field" is not a removed field of $model.',
        exitCode: _exitUsage,
      );
    }
    decidedFields.putIfAbsent(model, () => {}).add(field);
  }
  for (final name in options.dropCollections) {
    final isCollection = diff.removedCollections.any((c) => c.model == name);
    final isEmbedded = removedEmbedded.contains(name);
    if (!isCollection && !isEmbedded) {
      throw MigrateException(
        '--drop-collection $name: "$name" is not a removed collection or '
        'embedded class.',
        exitCode: _exitUsage,
      );
    }
    droppedNames.add(name);
  }

  final missing = <String>[];
  void decideRemoved({
    required String name,
    required List<FieldSpec> removed,
    required List<RenameCandidate> Function(FieldSpec) candidatesFor,
    required Map<String, Map<String, String>> renameMap,
  }) {
    for (final field in removed) {
      if (decidedFields[name]?.contains(field.name) ?? false) {
        continue;
      }
      final usedTargets = renameMap[name]?.values.toSet() ?? const <String>{};
      final candidates = candidatesFor(
        field,
      ).where((c) => !usedTargets.contains(c.to.name)).toList();
      if (candidates.isEmpty) {
        if (!io.stdinIsTerminal) {
          missing.add(
            '  - $name: `${field.name}` (${field.type}, #${field.number}) '
            'would be dropped: pass --drop $name.${field.name}',
          );
          continue;
        }
        if (_confirmFieldDrop(name, field, io)) {
          continue; // dropped: simply never added to the renames
        }
        throw MigrateException('Aborted; nothing was written.');
      }
      if (!io.stdinIsTerminal) {
        final best = candidates.first.to.name;
        missing.add(
          '  - $name: removed field `${field.name}` (${field.type}, '
          '#${field.number}): pass --rename $name.${field.name}=$best (or '
          '--drop $name.${field.name})',
        );
        continue;
      }
      if (options.yes) {
        // Default answers everywhere — but never for drops.
        renameMap.putIfAbsent(name, () => {})[field.name] =
            candidates.first.to.name;
        continue;
      }
      final chosen = _promptRenameMenu(name, field, candidates, io);
      if (chosen != null) {
        renameMap.putIfAbsent(name, () => {})[field.name] = chosen;
      }
    }
  }

  for (final collection in diff.collections) {
    if (collection.isNew) {
      continue;
    }
    decideRemoved(
      name: collection.declared.model,
      removed: collection.removed,
      candidatesFor: collection.candidatesFor,
      renameMap: renames,
    );
  }
  for (final embeddedClass in diff.embedded) {
    if (embeddedClass.isNew) {
      continue;
    }
    decideRemoved(
      name: embeddedClass.declared.name,
      removed: embeddedClass.removed,
      candidatesFor: embeddedClass.candidatesFor,
      renameMap: embeddedRenames,
    );
  }
  for (final removed in diff.removedCollections) {
    if (droppedNames.contains(removed.model)) {
      continue;
    }
    if (!io.stdinIsTerminal) {
      missing.add(
        '  - collection ${removed.model} has no model anymore: pass '
        '--drop-collection ${removed.model}',
      );
      continue;
    }
    if (!_confirmDrop(
      'Collection ${removed.model} has no model anymore. Drop it (existing '
      'documents become unreadable if the collection ever returns)?',
      io,
    )) {
      throw MigrateException('Aborted; nothing was written.');
    }
  }
  for (final name in removedEmbedded) {
    if (droppedNames.contains(name)) {
      continue;
    }
    if (!io.stdinIsTerminal) {
      missing.add(
        '  - embedded class $name has no model anymore: pass '
        '--drop-collection $name',
      );
      continue;
    }
    if (!_confirmDrop(
      'Embedded class $name has no model anymore. Drop it (its field numbers '
      'are lost; re-adding it later would misread old documents)?',
      io,
    )) {
      throw MigrateException('Aborted; nothing was written.');
    }
  }

  // Added required fields: a non-nullable field without a constructor
  // default would read its proto3 zero value in every document written
  // before it existed. Ask (or take --yes's default: a backfill stub),
  // unless a flag already decided the field.
  final renameTargets = <String, Set<String>>{};
  for (final MapEntry(key: model, value: targets) in renames.entries) {
    renameTargets[model] = targets.values.toSet();
  }
  for (final (collection, field) in _pendingRequiredFields(
    diff,
    classes,
    takenRenameTargets: renameTargets,
  )) {
    final model = collection.declared.model;
    if (backfilled[model]?.contains(field.name) ??
        keepZero[model]?.contains(field.name) ??
        false) {
      continue;
    }
    if (!io.stdinIsTerminal) {
      missing.add('  - ${_requiredFieldLine(collection, field)}');
      continue;
    }
    if (options.yes) {
      // The default answer is the backfill stub — never a silent keep-zero.
      backfilled.putIfAbsent(model, () => {}).add(field.name);
      continue;
    }
    if (_promptBackfillMenu(model, field, io)) {
      backfilled.putIfAbsent(model, () => {}).add(field.name);
    } else {
      keepZero.putIfAbsent(model, () => {}).add(field.name);
    }
  }

  if (missing.isNotEmpty) {
    throw MigrateException(
      'Non-interactive stdin with ${missing.length} decision(s) missing:\n'
      '${missing.join('\n')}',
      exitCode: _exitUsage,
    );
  }
  return (
    collections: renames,
    embedded: embeddedRenames,
    backfills: backfilled,
    keepZero: keepZero,
  );
}

/// The added fields of existing collections that old documents would read at
/// their proto3 zero value: non-nullable, no constructor default, a storable
/// scalar, not already recorded in the lock and — when [takenRenameTargets]
/// is given — not the target of a decided rename. Sorted by model and field
/// name, so prompts and reports are stable.
List<(CollectionDiff, DeclaredField)> _pendingRequiredFields(
  SchemaDiff diff,
  Map<String, ExtractedClass> classes, {
  Map<String, Set<String>> takenRenameTargets = const {},
}) {
  final pending = <(CollectionDiff, DeclaredField)>[];
  final collections = diff.collections.toList()
    ..sort((a, b) => a.declared.model.compareTo(b.declared.model));
  for (final collection in collections) {
    if (collection.isNew) {
      continue;
    }
    final clazz = classes[collection.declared.model];
    if (clazz == null) {
      continue;
    }
    final taken = takenRenameTargets[collection.declared.model] ?? const {};
    final fields = collection.added.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    for (final field in fields) {
      if (taken.contains(field.name)) {
        continue;
      }
      if (field.type.endsWith('?')) {
        continue;
      }
      if (clazz.defaults.containsKey(field.name)) {
        continue;
      }
      if (!_isStorableScalar(field.type)) {
        continue;
      }
      if (collection.previous!.keepZero.contains(field.name)) {
        continue;
      }
      pending.add((collection, field));
    }
  }
  return pending;
}

/// Whether an added field's type is a storable scalar (the types the
/// backfill question covers): lists, maps and embedded classes read empty
/// containers and zero instances, which need no decision.
bool _isStorableScalar(String canonicalType) {
  final base = _baseType(canonicalType);
  return !base.startsWith('List<') &&
      !base.startsWith('Map<') &&
      !base.startsWith('embedded:');
}

/// The value old documents read for a missing field of [canonicalType] —
/// the proto3 zero, as the question and `--check` show it.
String _zeroDisplay(String canonicalType) {
  final base = _baseType(canonicalType);
  return switch (base) {
    'int' => '0',
    'double' => '0.0',
    'bool' => 'false',
    'String' => "''",
    'DateTime' => 'the epoch (1970-01-01T00:00:00.000Z)',
    'Uint8List' => '<0 bytes>',
    _ when base.startsWith('enum:') => 'the first ${base.substring(5)} value',
    _ => 'its zero value',
  };
}

/// One pending added-required-field line: the question's facts and the flags
/// that would decide it (used by the missing-decision error and `--check`).
String _requiredFieldLine(CollectionDiff collection, DeclaredField field) {
  final model = collection.declared.model;
  return '$model: `${field.name}` (${field.type}) is new and required; '
      'existing documents would read ${_zeroDisplay(field.type)}: pass '
      '--backfill $model.${field.name} or --keep-zero $model.${field.name}';
}

/// The added-required-field menu: Enter (or 1) writes a backfill stub, 2
/// records "keep the zero value" in the lock, 3 aborts the run.
bool _promptBackfillMenu(String model, DeclaredField field, MigrateIo io) {
  io.write(
    '$model: `${field.name}` (${field.type}) is new and required. Existing '
    'documents would read ${_zeroDisplay(field.type)}.\n',
  );
  io.write(
    '  1) Write a backfill stub (a migration sets the value for existing '
    'documents) [default]\n',
  );
  io.write('  2) Keep the zero value (${_zeroDisplay(field.type)})\n');
  io.write('  3) Abort (add a default or make it nullable first)\n');
  while (true) {
    io.write('Choice [1]: ');
    final line = io.readLine().trim();
    if (line.isEmpty || line == '1') {
      return true;
    }
    if (line == '2') {
      return false;
    }
    if (line == '3') {
      throw MigrateException('Aborted; nothing was written.');
    }
    io.write('Enter a number between 1 and 3.\n');
  }
}

/// The field's canonical type as the model declares it — for the wire-type
/// validation of a decided backfill.
String _declaredFieldType(SchemaDiff diff, String model, String field) {
  for (final collection in diff.collections) {
    if (collection.declared.model != model) {
      continue;
    }
    for (final declared in collection.added) {
      if (declared.name == field) {
        return declared.type;
      }
    }
  }
  throw StateError('No added field $model.$field');
}

/// The collection diff and the embedded diff called [name] — at most one of
/// the two exists.
(CollectionDiff?, EmbeddedDiff?) _diffFor(SchemaDiff diff, String name) {
  for (final collection in diff.collections) {
    if (collection.declared.model == name) {
      return (collection, null);
    }
  }
  for (final embeddedClass in diff.embedded) {
    if (embeddedClass.declared.name == name) {
      return (null, embeddedClass);
    }
  }
  return (null, null);
}

/// The numbered rename menu: Enter picks the best candidate, a number picks
/// any option, and the last option drops the field (`null`).
String? _promptRenameMenu(
  String name,
  FieldSpec field,
  List<RenameCandidate> candidates,
  MigrateIo io,
) {
  io.write(
    '$name: `${field.name}` (${field.type}, #${field.number}) is gone and '
    'these are new:\n',
  );
  for (var i = 0; i < candidates.length; i++) {
    final candidate = candidates[i];
    final action = candidate.sameType
        ? 'rename, keep data'
        : 'rename, convert data';
    io.write(
      '  ${i + 1}) ${candidate.to.name} (${candidate.to.type})  $action\n',
    );
  }
  final dropOption = candidates.length + 1;
  io.write(
    '  $dropOption) drop ${field.name} (its number is reserved forever)\n',
  );
  while (true) {
    io.write('Choice [1]: ');
    final line = io.readLine().trim();
    if (line.isEmpty) {
      return candidates.first.to.name;
    }
    final number = int.tryParse(line);
    if (number == null || number < 1 || number > dropOption) {
      io.write('Enter a number between 1 and $dropOption.\n');
      continue;
    }
    if (number == dropOption) {
      return null;
    }
    return candidates[number - 1].to.name;
  }
}

bool _confirmFieldDrop(String name, FieldSpec field, MigrateIo io) =>
    _confirmDrop(
      '$name: `${field.name}` (${field.type}, #${field.number}) is gone. '
      'Drop it (number ${field.number} is reserved forever)?',
      io,
    );

bool _confirmDrop(String question, MigrateIo io) {
  while (true) {
    io.write('$question [y/N] ');
    final answer = io.readLine().trim().toLowerCase();
    if (answer.isEmpty || answer == 'n' || answer == 'no') {
      return false;
    }
    if (answer == 'y' || answer == 'yes') {
      return true;
    }
    io.write('Answer y or n.\n');
  }
}

/// A one-line-per-model summary of what the diff would change (for
/// `--check` and refusals).
String _describeChanges(SchemaDiff diff) {
  final lines = <String>[];
  for (final collection in diff.collections) {
    if (!collection.isEmpty) {
      lines.add(
        '  ${collection.declared.model}: '
        '${describeCollectionDiff(collection)}',
      );
    }
  }
  for (final embeddedClass in diff.embedded) {
    if (!embeddedClass.isEmpty) {
      lines.add(
        '  ${embeddedClass.declared.name}: '
        '${describeEmbeddedDiff(embeddedClass)}',
      );
    }
  }
  for (final removed in diff.removedCollections) {
    lines.add('  ${removed.model}: collection removed');
  }
  return 'The schema would change:\n${lines.join('\n')}\n';
}

// -- Writes -------------------------------------------------------------------

/// Writes the committed lock as `cocoon.lock` (YAML), deleting the legacy
/// `cocoon.lock.json` when this run converted it. The conversion message
/// tells the developer to commit both changes and to point build.yaml's
/// sources at the new name — the builder can only read assets the target's
/// sources list.
void _writeLockFile(
  String root,
  SchemaLock lock,
  bool converted,
  MigrateIo io,
) {
  File('$root/$lockFileName').writeAsStringSync(lockYamlSource(lock));
  io.write(
    '${_color('Wrote $lockFileName (version ${lock.version}).', _ansiGreen, io.stdoutIsTerminal)}\n',
  );
  if (converted) {
    File('$root/$legacyLockFileName').deleteSync();
    io.write(
      'Converted the legacy $legacyLockFileName to $lockFileName: commit '
      'both changes (the new file and the deletion), and switch '
      "build.yaml's sources entry to $lockFileName.\n",
    );
  }
}

/// Writes `lib/cocoon_migrations/m<NNNN>_<summary>.dart` with one typed
/// conversion stub per upgrade and one document-backfill stub per added
/// required field. Returns whether a file was written.
bool _writeMigrationFile(
  String root,
  int version,
  Map<String, List<FieldUpgrade>> upgrades,
  Map<String, Set<String>> backfills,
  SchemaLock newLock,
  Map<String, String> modelLibraries,
  MigrateIo io,
) {
  final dir = Directory('$root/lib/cocoon_migrations');
  dir.createSync(recursive: true);
  final name =
      'm${_pad4(version)}_${_migrationSummary(upgrades, backfills)}.dart';
  final listName = 'm${_pad4(version)}Migrations';
  final backfillListName = 'm${_pad4(version)}Backfills';
  final hasUpgrades = upgrades.isNotEmpty;
  final sortedModels = {...upgrades.keys, ...backfills.keys}.toList()..sort();
  final buffer = StringBuffer()
    ..writeln(
      '// GENERATED CODE - DO NOT MODIFY BY HAND, except the conversion bodies.',
    )
    ..writeln('//')
    ..writeln('// Cocoon schema migration to version $version, written by')
    ..writeln('// `dart run cocoon_generator:migrate`. Implement every')
    ..writeln(
      '// `upgrade...` and `backfill...` function below, then run build_runner',
    )
    ..writeln(
      '// again: the build fails while any `UnimplementedError` remains.',
    )
    ..writeln();
  for (final model in sortedModels) {
    for (final upgrade in upgrades[model] ?? const <FieldUpgrade>[]) {
      buffer.writeln(
        '// $model.${upgrade.from.name}: ${upgrade.from.type} '
        '(#${upgrade.from.number}) -> ${upgrade.to.name}: '
        '${upgrade.to.type} (#${upgrade.to.number})',
      );
    }
    for (final field in backfills[model] ?? const <String>[]) {
      final spec = newLock.collections[model]!.field(field)!;
      buffer.writeln(
        '// $model.$field: ${spec.type} (#${spec.number}) added and required; '
        'a backfill sets it on existing documents',
      );
    }
  }
  buffer
    ..writeln()
    ..writeln("import 'package:cocoon/cocoon.dart';");
  if (backfills.isNotEmpty) {
    final imports = [
      for (final model in sortedModels)
        if (backfills[model]?.isNotEmpty ?? false)
          _modelImport(modelLibraries[model], dir.path),
    ]..sort();
    for (final import in imports.toSet()) {
      buffer.writeln("import '$import';");
    }
  }
  buffer.writeln();
  final functions = <String>[];
  for (final model in sortedModels) {
    for (final upgrade in upgrades[model] ?? const <FieldUpgrade>[]) {
      final function = _upgradeFunctionName(model, upgrade.from.name);
      functions.add(function);
      final fromType = _stubType(
        upgrade.from.type,
        '$model.${upgrade.from.name}',
      );
      final toType = _stubType(upgrade.to.type, '$model.${upgrade.to.name}');
      buffer
        ..writeln(
          '/// Converts $model.${upgrade.from.name} '
          '(${upgrade.from.type}, #${upgrade.from.number})',
        )
        ..writeln(
          '/// to ${upgrade.to.name} (${upgrade.to.type}, '
          '#${upgrade.to.number}).',
        )
        ..writeln(
          '$toType $function($fromType old) => '
          "throw UnimplementedError('Write the conversion');",
        )
        ..writeln();
    }
  }
  final backfillFunctions = <String>[];
  for (final model in sortedModels) {
    for (final field in backfills[model] ?? const <String>[]) {
      final spec = newLock.collections[model]!.field(field)!;
      final function = _backfillFunctionName(model, field);
      backfillFunctions.add(function);
      buffer
        ..writeln(
          '/// Fills $model.$field for documents written before the field',
        )
        ..writeln('/// existed. [doc] is the existing document: `$field` reads')
        ..writeln(
          '/// its zero value on it, every other field the value the previous',
        )
        ..writeln(
          '/// migrations left. Return the value to store — it may depend on',
        )
        ..writeln('/// any of the document\'s other fields.')
        ..writeln(
          '${_backfillValueType(spec.type)} $function($model doc) => '
          "throw UnimplementedError('Write the backfill');",
        )
        ..writeln();
    }
  }
  if (hasUpgrades) {
    buffer
      ..writeln(
        "/// The field rewrites of this migration, listed by 'migrations.dart'.",
      )
      ..writeln('final $listName = <FieldMigration>[');
    var index = 0;
    for (final model in sortedModels) {
      for (final upgrade in upgrades[model] ?? const <FieldUpgrade>[]) {
        final context = '$model.${upgrade.from.name}';
        final fromBase = _baseType(upgrade.from.type);
        final toBase = _baseType(upgrade.to.type);
        final fromIsMap = fromBase.startsWith('Map<');
        final toIsMap = toBase.startsWith('Map<');
        if (fromIsMap) {
          // FieldMigration.typed<...> needs a Dart type argument per side; map
          // types carry commas, so map rewrites use the untyped constructor
          // and describe their shape with fromMap/toMap below.
          buffer.writeln('  FieldMigration(');
        } else {
          final fromType = _stubType(upgrade.from.type, context);
          final toType = _stubType(upgrade.to.type, context);
          buffer.writeln('  FieldMigration.typed<$fromType, $toType>(');
        }
        buffer
          ..writeln("    model: '$model',")
          ..writeln("    fromName: '${upgrade.from.name}',")
          ..writeln('    fromNumber: ${upgrade.from.number},')
          ..writeln("    fromType: '${_literalType(upgrade.from.type)}',")
          ..writeln(
            '    fromWire: MigrationWireType.'
            '${_wireTypeOf(upgrade.from.type, context)},',
          );
        if (fromIsMap) {
          final (key: key, value: value) = _splitMapType(fromBase, context);
          buffer
            ..writeln('    fromMap: MapWireType(')
            ..writeln(
              '      key: MigrationWireType.${_mapKeyWire(key, context)},',
            )
            ..writeln(
              '      value: MigrationWireType.'
              '${_wireTypeOf(value, context)},',
            )
            ..writeln('    ),');
        }
        buffer
          ..writeln("    toName: '${upgrade.to.name}',")
          ..writeln('    toNumber: ${upgrade.to.number},')
          ..writeln("    toType: '${_literalType(upgrade.to.type)}',")
          ..writeln(
            '    toWire: MigrationWireType.'
            '${_wireTypeOf(upgrade.to.type, context)},',
          );
        if (toIsMap) {
          final (key: key, value: value) = _splitMapType(toBase, context);
          buffer
            ..writeln('    toMap: MapWireType(')
            ..writeln(
              '      key: MigrationWireType.${_mapKeyWire(key, context)},',
            )
            ..writeln(
              '      value: MigrationWireType.'
              '${_wireTypeOf(value, context)},',
            )
            ..writeln('    ),');
        }
        if (fromIsMap) {
          // The decoded old value is a Map<Object?, Object?>; the stub takes
          // the field's real map type, so cast first. A cast view keeps the
          // conversion type-checked without copying the entries.
          final (key: key, value: value) = _splitMapType(fromBase, context);
          buffer
            ..writeln('    convert: (value) => ${functions[index]}(')
            ..writeln(
              '      (value! as Map<Object?, Object?>).cast<'
              '${_stubType(key, context)}, ${_stubType(value, context)}>(),',
            )
            ..writeln('    ),');
        } else {
          buffer.writeln('    convert: ${functions[index]},');
        }
        buffer.writeln('  ),');
        index++;
      }
    }
    buffer.writeln('];');
  }
  if (backfills.isNotEmpty) {
    buffer
      ..writeln(
        "/// The document backfills of this migration, listed by 'migrations.dart'.",
      )
      ..writeln('final $backfillListName = <BackfillMigration<Object?>>[');
    for (final model in sortedModels) {
      for (final field in backfills[model] ?? const <String>[]) {
        final spec = newLock.collections[model]!.field(field)!;
        buffer
          ..writeln('  BackfillMigration<$model>(')
          ..writeln("    model: '$model',")
          ..writeln("    fieldName: '$field',")
          ..writeln('    fieldNumber: ${spec.number},')
          ..writeln("    fieldType: '${_literalType(spec.type)}',")
          ..writeln(
            '    wire: MigrationWireType.'
            '${_wireTypeOf(spec.type, '$model.$field')},',
          )
          ..writeln(
            '    backfill: ${backfillFunctions[_backfillIndex(backfills, model, field)]},',
          )
          ..writeln('  ),');
      }
    }
    buffer.writeln('];');
  }
  // No trailing blank line at EOF: the emitted files stay dart-format
  // stable as written.
  if (!buffer.toString().endsWith('\n')) {
    buffer.writeln();
  }
  File('${dir.path}/$name').writeAsStringSync(buffer.toString());
  io.write(
    '${_color('Wrote lib/cocoon_migrations/$name.', _ansiGreen, io.stdoutIsTerminal)}\n',
  );
  return true;
}

/// The 0-based position of a backfill field in the sorted emission order, so
/// the list references the stub function written for it.
int _backfillIndex(
  Map<String, Set<String>> backfills,
  String model,
  String field,
) {
  final models = backfills.keys.toList()..sort();
  var index = 0;
  for (final m in models) {
    final fields = backfills[m]!.toList()..sort();
    if (m == model) {
      return index + fields.indexOf(field);
    }
    index += fields.length;
  }
  throw StateError('No backfill $model.$field');
}

/// The import of the library that declares [model]'s class, as the backfill
/// stub file needs it: package URIs are used as-is, file URIs become a
/// relative path from the migrations directory.
String _modelImport(String? libraryUri, String migrationDir) {
  final uri = libraryUri ?? '';
  if (uri.startsWith('file:')) {
    final modelPath = Uri.parse(uri).toFilePath(windows: false);
    final from = migrationDir.endsWith('/') ? migrationDir : '$migrationDir/';
    final model = modelPath.startsWith('/')
        ? modelPath.substring(1)
        : modelPath;
    final base = from.startsWith('/') ? from.substring(1) : from;
    final modelParts = model.split('/')..removeLast();
    final baseParts = base.split('/')..removeLast();
    var common = 0;
    while (common < modelParts.length &&
        common < baseParts.length &&
        modelParts[common] == baseParts[common]) {
      common++;
    }
    return [
      for (var i = common; i < baseParts.length; i++) '..',
      ...modelParts.skip(common),
    ].join('/');
  }
  return uri;
}

/// (Re)generates `lib/cocoon_migrations/migrations.dart`: every migration
/// file of the package, oldest first. Skipped when there is none.
void _writeMigrationsList(String root, MigrateIo io) {
  final dir = Directory('$root/lib/cocoon_migrations');
  if (!dir.existsSync()) {
    return;
  }
  final files = <(int, String)>[];
  final sources = <String, String>{};
  for (final entry in dir.listSync()) {
    if (entry is! File) {
      continue;
    }
    final name = entry.uri.pathSegments.last;
    final match = RegExp(r'^m(\d{4})_.+\.dart$').firstMatch(name);
    if (match != null) {
      files.add((int.parse(match.group(1)!), name));
      sources[name] = entry.readAsStringSync();
    }
  }
  if (files.isEmpty) {
    return;
  }
  files.sort((a, b) => a.$1.compareTo(b.$1));
  final buffer = StringBuffer()
    ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND.')
    ..writeln('//')
    ..writeln(
      '// Regenerated by `dart run cocoon_generator:migrate`: every migration',
    )
    ..writeln(
      '// file of this package, oldest first. Hand `cocoonMigrations` (with',
    )
    ..writeln(
      "// `cocoonSchemaVersion`) to `Cocoon.open`'s `migrations:` parameter.",
    )
    ..writeln()
    ..writeln("import 'package:cocoon/cocoon.dart';");
  for (final (version, name) in files) {
    buffer.writeln("import '$name' as m${_pad4(version)};");
  }
  buffer
    ..writeln()
    ..writeln(
      '/// Every Cocoon schema migration of this package, oldest first.',
    )
    ..writeln('final cocoonMigrations = <CocoonMigration>[');
  for (final (version, name) in files) {
    final prefix = 'm${_pad4(version)}';
    // A migration file declares exactly the lists it carries: field rewrites
    // (`mNNNNMigrations`) and/or document backfills (`mNNNNBackfills`).
    final parts = <String>['version: $version'];
    if (sources[name]!.contains('final ${prefix}Migrations =')) {
      parts.add('fields: $prefix.${prefix}Migrations');
    }
    if (sources[name]!.contains('final ${prefix}Backfills =')) {
      parts.add('backfills: $prefix.${prefix}Backfills');
    }
    buffer.writeln('  CocoonMigration(${parts.join(', ')}),');
  }
  buffer.writeln('];');
  File('${dir.path}/migrations.dart').writeAsStringSync(buffer.toString());
  io.write(
    '${_color('Wrote lib/cocoon_migrations/migrations.dart.', _ansiGreen, io.stdoutIsTerminal)}\n',
  );
}

// -- Small helpers -------------------------------------------------------------

/// `Staff.staffId` -> `upgradeStaffStaffId`.
String _upgradeFunctionName(String model, String field) =>
    'upgrade${_pascal(model)}${_pascal(field)}';

/// `Txn.currency` -> `backfillTxnCurrency`.
String _backfillFunctionName(String model, String field) =>
    'backfill${_pascal(model)}${_pascal(field)}';

/// The Dart type of a backfill stub's return: the field's REAL type as the
/// model declares it — the stub returns a value, not a stored
/// representation (`DateTime` fields take a `DateTime`, enums the enum).
String _backfillValueType(String canonicalType) {
  final base = _baseType(canonicalType);
  if (base.startsWith('enum:')) {
    return base.substring(5);
  }
  return switch (base) {
    'int' ||
    'double' ||
    'bool' ||
    'String' ||
    'DateTime' ||
    'Uint8List' => base,
    _ => throw MigrateException(
      'Cannot generate a backfill for "$canonicalType": it is not a storable '
      'scalar. Make the field nullable or give it a constructor default '
      'instead.',
    ),
  };
}

String _pascal(String name) =>
    name.isEmpty ? name : '${name[0].toUpperCase()}${name.substring(1)}';

/// The migration file name's summary: `txn_currency_to_currency_code`, plus
/// one `model_field_backfill` part per backfill.
String _migrationSummary(
  Map<String, List<FieldUpgrade>> upgrades,
  Map<String, Set<String>> backfills,
) {
  final parts = <String>[];
  for (final model in upgrades.keys.toList()..sort()) {
    for (final upgrade in upgrades[model]!) {
      parts.add(
        '${snakeCase(model)}_${snakeCase(upgrade.from.name)}_to_'
        '${snakeCase(upgrade.to.name)}',
      );
    }
  }
  for (final model in backfills.keys.toList()..sort()) {
    final fields = backfills[model]!.toList()..sort();
    for (final field in fields) {
      parts.add('${snakeCase(model)}_${snakeCase(field)}_backfill');
    }
  }
  return parts.join('_and_');
}

String _pad4(int version) => version.toString().padLeft(4, '0');

/// The Dart type of a migration stub's parameter/return: the field's stored
/// representation. `DateTime` values are microseconds, enums their name, and
/// only present values are converted (never null). Map fields convert as
/// `Map<K, V>` of their parts' stored representations.
String _stubType(String canonicalType, String context) {
  final base = _baseType(canonicalType);
  if (base.startsWith('Map<')) {
    final (key: key, value: value) = _splitMapType(base, context);
    final keyStub = switch (key) {
      'String' => 'String',
      'int' => 'int',
      _ => throw MigrateException(
        'Cannot generate a conversion for $context: map keys must be String '
        'or int, not "$key".',
      ),
    };
    final valueStub = _stubType(value, context);
    return 'Map<$keyStub, $valueStub>';
  }
  return switch (base) {
    'int' || 'DateTime' => 'int',
    'double' => 'double',
    'bool' => 'bool',
    'String' => 'String',
    'Uint8List' => 'Uint8List',
    _ when base.startsWith('enum:') => 'String',
    _ => throw MigrateException(
      'Cannot generate a conversion for $context: "$canonicalType" is not a '
      'storable scalar. Change the field in two steps instead: add the new '
      'field, backfill it in app code, then remove the old one.',
    ),
  };
}

/// The exact wire encoding of a field's values, mirroring the code
/// generator: ints and DateTimes are zigzag sint64, doubles i64, bools
/// varint, strings and enums UTF-8 text, bytes length-delimited, maps a
/// sequence of entry messages.
String _wireTypeOf(String canonicalType, String context) {
  final base = _baseType(canonicalType);
  if (base.startsWith('Map<')) {
    return 'map';
  }
  return switch (base) {
    'int' || 'DateTime' => 'sint64',
    'double' => 'float64',
    'bool' => 'boolean',
    'String' => 'text',
    'Uint8List' => 'bytes',
    _ when base.startsWith('enum:') => 'text',
    _ => throw MigrateException(
      'Cannot migrate $context: "$canonicalType" has no scalar wire encoding.',
    ),
  };
}

/// Splits a canonical map type `Map<K,V>` into its key and value canonical
/// types: the key is a simple type, so the first comma is the separator.
({String key, String value}) _splitMapType(String base, String context) {
  final comma = base.indexOf(',');
  if (comma < 0) {
    throw MigrateException(
      'Cannot migrate $context: "$base" is not a valid map type.',
    );
  }
  return (
    key: base.substring(4, comma),
    value: base.substring(comma + 1, base.length - 1),
  );
}

/// The wire encoding of a map key canonical type.
String _mapKeyWire(String key, String context) => switch (key) {
  'String' => 'text',
  'int' => 'sint64',
  _ => throw MigrateException(
    'Cannot migrate $context: map keys must be String or int, not "$key".',
  ),
};

String _baseType(String canonicalType) => canonicalType.endsWith('?')
    ? canonicalType.substring(0, canonicalType.length - 1)
    : canonicalType;

/// The lock's canonical type as a safe single-quoted Dart string literal.
String _literalType(String canonicalType) =>
    canonicalType.replaceAll("'", r"\'");

const _ansiGreen = '\x1B[32m';
const _ansiRed = '\x1B[31m';
const _ansiYellow = '\x1B[33m';

String _color(String text, String code, bool enabled) =>
    enabled ? '$code$text\x1B[0m' : text;

_Options _parseArgs(List<String> args) {
  final renames = <(String, String, String)>[];
  final drops = <(String, String)>[];
  final dropCollections = <String>[];
  final backfills = <(String, String)>[];
  final keepZeros = <(String, String)>[];
  var yes = false;
  var check = false;
  const name = '[A-Za-z_][A-Za-z0-9_]*';
  final renamePattern = RegExp('^($name)\\.($name)=($name)');
  final fieldPattern = RegExp('^($name)\\.($name)');

  String valueOf(String flag, int index) {
    if (index + 1 >= args.length) {
      throw MigrateException('$flag needs a value.', exitCode: _exitUsage);
    }
    return args[index + 1];
  }

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--yes') {
      yes = true;
    } else if (arg == '--check') {
      check = true;
    } else if (arg == '--rename' || arg.startsWith('--rename=')) {
      final value = arg == '--rename'
          ? valueOf('--rename', i++)
          : arg.substring('--rename='.length);
      final match = renamePattern.firstMatch(value);
      if (match == null) {
        throw MigrateException(
          '--rename expects Model.old=new, got "$value".',
          exitCode: _exitUsage,
        );
      }
      renames.add((match.group(1)!, match.group(2)!, match.group(3)!));
    } else if (arg == '--drop' || arg.startsWith('--drop=')) {
      final value = arg == '--drop'
          ? valueOf('--drop', i++)
          : arg.substring('--drop='.length);
      final match = fieldPattern.firstMatch(value);
      if (match == null) {
        throw MigrateException(
          '--drop expects Model.field, got "$value".',
          exitCode: _exitUsage,
        );
      }
      drops.add((match.group(1)!, match.group(2)!));
    } else if (arg == '--backfill' || arg.startsWith('--backfill=')) {
      final value = arg == '--backfill'
          ? valueOf('--backfill', i++)
          : arg.substring('--backfill='.length);
      final match = fieldPattern.firstMatch(value);
      if (match == null) {
        throw MigrateException(
          '--backfill expects Model.field, got "$value".',
          exitCode: _exitUsage,
        );
      }
      backfills.add((match.group(1)!, match.group(2)!));
    } else if (arg == '--keep-zero' || arg.startsWith('--keep-zero=')) {
      final value = arg == '--keep-zero'
          ? valueOf('--keep-zero', i++)
          : arg.substring('--keep-zero='.length);
      final match = fieldPattern.firstMatch(value);
      if (match == null) {
        throw MigrateException(
          '--keep-zero expects Model.field, got "$value".',
          exitCode: _exitUsage,
        );
      }
      keepZeros.add((match.group(1)!, match.group(2)!));
    } else if (arg == '--drop-collection' ||
        arg.startsWith('--drop-collection=')) {
      final value = arg == '--drop-collection'
          ? valueOf('--drop-collection', i++)
          : arg.substring('--drop-collection='.length);
      if (!RegExp('^$name\$').hasMatch(value)) {
        throw MigrateException(
          '--drop-collection expects a model name, got "$value".',
          exitCode: _exitUsage,
        );
      }
      dropCollections.add(value);
    } else {
      throw MigrateException(
        'Unknown argument "$arg". Usage: dart run cocoon_generator:migrate '
        '[--rename Model.old=new]... [--drop Model.field]... '
        '[--drop-collection Model]... [--backfill Model.field]... '
        '[--keep-zero Model.field]... [--yes] [--check]',
        exitCode: _exitUsage,
      );
    }
  }
  return _Options(
    renames: renames,
    drops: drops,
    dropCollections: dropCollections,
    backfills: backfills,
    keepZeros: keepZeros,
    yes: yes,
    check: check,
  );
}

/// Walks up from [start] (default: the working directory) to the nearest
/// `pubspec.yaml`. Shared with the `index add` command.
String findPackageRoot(String? start) {
  var dir = Directory(start ?? Directory.current.path).absolute.path;
  if (dir.endsWith(Platform.pathSeparator)) {
    dir = dir.substring(0, dir.length - 1);
  }
  while (true) {
    if (File('$dir/pubspec.yaml').existsSync()) {
      return dir;
    }
    final parent = Directory(dir).parent.path;
    if (parent == dir) {
      throw MigrateException(
        'No pubspec.yaml above ${start ?? Directory.current.path}; run the '
        'command from inside a package.',
      );
    }
    dir = parent;
  }
}
