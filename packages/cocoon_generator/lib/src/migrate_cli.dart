/// The `dart run cocoon_generator:migrate` command.
///
/// Diffs the models of the current package against its committed
/// `cocoon.lock.json`, asks the developer only the questions a human must
/// answer — which removed field was renamed to which new one, and whether a
/// field or collection is really dropped — and writes the new lock plus,
/// only when stored data must change, a numbered migration file under
/// `lib/cocoon_migrations/`.
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
}

/// The parsed command line.
final class _Options {
  const _Options({
    required this.renames,
    required this.drops,
    required this.dropCollections,
    required this.yes,
    required this.check,
  });

  /// `--rename Model.old=new`: model, old field name, new field name.
  final List<(String, String, String)> renames;

  /// `--drop Model.field`: explicit drops.
  final List<(String, String)> drops;

  /// `--drop-collection Model` (also accepted for removed embedded classes).
  final List<String> dropCollections;

  /// `--yes`: accept the default answer of every rename menu. Drop
  /// confirmations are never covered: drops must be explicit flags.
  final bool yes;

  /// `--check`: exit 1 when the lock would change; never writes.
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
  final root = _findPackageRoot(packageRoot);
  final libPath = '$root/lib';
  if (!Directory(libPath).existsSync()) {
    throw MigrateException(
      'No lib/ directory under $root.',
      exitCode: _exitUsage,
    );
  }

  final (:models, :embedded) = await _extractDeclarations(libPath);
  final lockFile = File('$root/cocoon.lock.json');
  final lock = lockFile.existsSync()
      ? SchemaLock.parse(lockFile.readAsStringSync())
      : SchemaLock.empty();
  final diff = SchemaDiff.compute(
    lock,
    [for (final model in models) model.declared],
    [for (final e in embedded) e.declared],
  );

  if (diff.isEmpty) {
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
    io.write(_describeChanges(diff));
    io.write(
      '${_color('cocoon.lock.json was not written (--check).', _ansiYellow, io.stdoutIsTerminal)}\n',
    );
    return _exitAborted;
  }

  final removedEmbedded = [
    for (final name in lock.embedded.keys)
      if (!diff.embedded.any((e) => e.declared.name == name)) name,
  ]..sort();

  final renames = _decide(diff, removedEmbedded, options, io);

  final (lock: newLock, upgrades: upgrades) = diff.resolve(
    renames: renames.collections,
    embeddedRenames: renames.embedded,
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
  lockFile.writeAsStringSync(newLock.toSource());
  io.write(
    '${_color('Wrote cocoon.lock.json (version ${newLock.version}).', _ansiGreen, io.stdoutIsTerminal)}\n',
  );

  if (upgrades.isNotEmpty) {
    _writeMigrationFile(root, newLock.version, upgrades, io);
    io.write(
      'Next: implement the `upgrade...` functions in the new migration file, '
      'then run build_runner.\n',
    );
  }
  _writeMigrationsList(root, io);
  return 0;
}

// -- Extraction -------------------------------------------------------------

typedef _Declarations = ({
  List<ExtractedModel> models,
  List<ExtractedEmbedded> embedded,
});

Future<_Declarations> _extractDeclarations(String libPath) async {
  final contexts = AnalysisContextCollection(includedPaths: [libPath]);
  final models = <ExtractedModel>[];
  final embedded = <ExtractedEmbedded>[];
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
      for (final model in declarations.models) {
        if (!modelNames.add(model.clazz.name)) {
          throw MigrateException(
            'Model ${model.clazz.name} is declared in more than one library '
            'under lib/; one name must be one collection.',
          );
        }
        models.add(model);
      }
      for (final embeddedClass in declarations.embedded) {
        if (embeddedNames.add(embeddedClass.clazz.name)) {
          embedded.add(embeddedClass);
        }
      }
    }
  }
  return (models: models, embedded: embedded);
}

// -- Decisions ----------------------------------------------------------------

/// The rename decisions of one migrate run, split the way
/// `SchemaDiff.resolve` takes them.
typedef _Renames = ({
  Map<String, Map<String, String>> collections,
  Map<String, Map<String, String>> embedded,
});

/// Works out every decision before resolving: flags first (validated
/// against the diff), then prompts for the rest. On non-interactive stdin a
/// missing decision throws with the flags that would resolve it; a `No` at
/// any drop confirmation aborts without writing.
_Renames _decide(
  SchemaDiff diff,
  List<String> removedEmbedded,
  _Options options,
  MigrateIo io,
) {
  final renames = <String, Map<String, String>>{};
  final embeddedRenames = <String, Map<String, String>>{};
  final decidedFields = <String, Set<String>>{};
  final droppedNames = <String>{};

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

  if (missing.isNotEmpty) {
    throw MigrateException(
      'Non-interactive stdin with ${missing.length} decision(s) missing:\n'
      '${missing.join('\n')}',
      exitCode: _exitUsage,
    );
  }
  return (collections: renames, embedded: embeddedRenames);
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

/// Writes `lib/cocoon_migrations/m<NNNN>_<summary>.dart` with one typed
/// conversion stub per upgrade. Returns whether a file was written.
bool _writeMigrationFile(
  String root,
  int version,
  Map<String, List<FieldUpgrade>> upgrades,
  MigrateIo io,
) {
  final dir = Directory('$root/lib/cocoon_migrations');
  dir.createSync(recursive: true);
  final name = 'm${_pad4(version)}_${_upgradeSummary(upgrades)}.dart';
  final listName = 'm${_pad4(version)}Migrations';
  final sortedModels = upgrades.keys.toList()..sort();
  final buffer = StringBuffer()
    ..writeln(
      '// GENERATED CODE - DO NOT MODIFY BY HAND, except the conversion bodies.',
    )
    ..writeln('//')
    ..writeln('// Cocoon schema migration to version $version, written by')
    ..writeln('// `dart run cocoon_generator:migrate`. Implement every')
    ..writeln(
      '// `upgrade...` function below, then run build_runner again: the build',
    )
    ..writeln('// fails while any `UnimplementedError` remains.')
    ..writeln();
  for (final model in sortedModels) {
    for (final upgrade in upgrades[model]!) {
      buffer.writeln(
        '// $model.${upgrade.from.name}: ${upgrade.from.type} '
        '(#${upgrade.from.number}) -> ${upgrade.to.name}: '
        '${upgrade.to.type} (#${upgrade.to.number})',
      );
    }
  }
  buffer
    ..writeln()
    ..writeln("import 'package:cocoon/cocoon.dart';")
    ..writeln();
  final functions = <String>[];
  for (final model in sortedModels) {
    for (final upgrade in upgrades[model]!) {
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
  buffer
    ..writeln(
      "/// The field rewrites of this migration, listed by 'migrations.dart'.",
    )
    ..writeln('final $listName = <FieldMigration>[');
  var index = 0;
  for (final model in sortedModels) {
    for (final upgrade in upgrades[model]!) {
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
  // No trailing blank line at EOF: the emitted files stay dart-format
  // stable as written.
  buffer.writeln('];');
  File('${dir.path}/$name').writeAsStringSync(buffer.toString());
  io.write(
    '${_color('Wrote lib/cocoon_migrations/$name.', _ansiGreen, io.stdoutIsTerminal)}\n',
  );
  return true;
}

/// (Re)generates `lib/cocoon_migrations/migrations.dart`: every migration
/// file of the package, oldest first. Skipped when there is none.
void _writeMigrationsList(String root, MigrateIo io) {
  final dir = Directory('$root/lib/cocoon_migrations');
  if (!dir.existsSync()) {
    return;
  }
  final files = <(int, String)>[];
  for (final entry in dir.listSync()) {
    if (entry is! File) {
      continue;
    }
    final name = entry.uri.pathSegments.last;
    final match = RegExp(r'^m(\d{4})_.+\.dart$').firstMatch(name);
    if (match != null) {
      files.add((int.parse(match.group(1)!), name));
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
  for (final (version, _) in files) {
    buffer.writeln(
      '  CocoonMigration(version: $version, fields: '
      'm${_pad4(version)}.m${_pad4(version)}Migrations),',
    );
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

String _pascal(String name) =>
    name.isEmpty ? name : '${name[0].toUpperCase()}${name.substring(1)}';

/// The migration file name's summary: `txn_currency_to_currency_code`.
String _upgradeSummary(Map<String, List<FieldUpgrade>> upgrades) {
  final parts = <String>[];
  for (final model in upgrades.keys.toList()..sort()) {
    for (final upgrade in upgrades[model]!) {
      parts.add(
        '${snakeCase(model)}_${snakeCase(upgrade.from.name)}_to_'
        '${snakeCase(upgrade.to.name)}',
      );
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
  var yes = false;
  var check = false;
  const name = '[A-Za-z_][A-Za-z0-9_]*';
  final renamePattern = RegExp('^($name)\\.($name)=($name)');
  final dropPattern = RegExp('^($name)\\.($name)');

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
      final match = dropPattern.firstMatch(value);
      if (match == null) {
        throw MigrateException(
          '--drop expects Model.field, got "$value".',
          exitCode: _exitUsage,
        );
      }
      drops.add((match.group(1)!, match.group(2)!));
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
        '[--drop-collection Model]... [--yes] [--check]',
        exitCode: _exitUsage,
      );
    }
  }
  return _Options(
    renames: renames,
    drops: drops,
    dropCollections: dropCollections,
    yes: yes,
    check: check,
  );
}

/// Walks up from [start] (default: the working directory) to the nearest
/// `pubspec.yaml`.
String _findPackageRoot(String? start) {
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
