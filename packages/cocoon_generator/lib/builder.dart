/// The build_runner entry points of cocoon_generator.
///
/// * `cocoonBuilder` generates a `*.cocoon.dart` part file for every library
///   with `@Collection` models (declare the part in the model file).
/// * `cocoonSchemaVersionBuilder` emits `lib/cocoon_schema.g.dart` with the
///   package's `cocoonSchemaVersion` constant, from the committed
///   `cocoon.lock`.
///
/// The builder never writes `cocoon.lock`; when models and lock
/// disagree it fails with the `cocoon migrate` instruction.
library;

import 'dart:async';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:build/build.dart';
import 'package:cocoon/cocoon.dart';
import 'package:glob/glob.dart';
import 'package:source_gen/source_gen.dart';

import 'src/extract.dart';
import 'src/emitter.dart';
import 'src/lock_yaml.dart';

/// The failure for a package that carries both lock files: the builder never
/// guesses which one is current.
const String _bothLockFilesMessage =
    'Both $lockFileName and $legacyLockFileName exist in this package; '
    'delete one of them ($lockFileName is the file `cocoon migrate` '
    'maintains today) and run the build again.';

/// Reads the package's committed lock: `cocoon.lock` (YAML) when present,
/// else the legacy `cocoon.lock.json` JSON. Both present throws
/// [_bothLockFilesMessage]; neither throws [orMissing].
Future<SchemaLock> _readLock(
  BuildStep buildStep, {
  required CocoonBuildError Function() orMissing,
}) async {
  final package = buildStep.inputId.package;
  final lockId = AssetId(package, lockFileName);
  final legacyId = AssetId(package, legacyLockFileName);
  final hasYaml = await buildStep.canRead(lockId);
  final hasJson = await buildStep.canRead(legacyId);
  if (hasYaml && hasJson) {
    throw CocoonBuildError(_bothLockFilesMessage);
  }
  if (!hasYaml && !hasJson) {
    throw orMissing();
  }
  final text = await buildStep.readAsString(hasYaml ? lockId : legacyId);
  return hasYaml ? parseLockYaml(text) : SchemaLock.parse(text);
}

/// The build_runner builder emitting `*.cocoon.dart` part files.
Builder cocoonBuilder(BuilderOptions options) =>
    PartBuilder([const CocoonGenerator()], '.cocoon.dart');

/// The build_runner builder emitting `lib/cocoon_schema.g.dart`.
Builder cocoonSchemaVersionBuilder(BuilderOptions options) =>
    const _CocoonSchemaVersionBuilder();

/// The source_gen generator behind [cocoonBuilder]: runs once per library,
/// generating the adapters, typed handles and codecs of its `@Collection`
/// models (and of every `@Embedded` class they reference).
class CocoonGenerator extends Generator {
  const CocoonGenerator();

  @override
  Future<String?> generate(LibraryReader library, BuildStep buildStep) async {
    final declarations = extractLibrary(library);
    if (declarations == null) {
      return null;
    }
    await _requirePartDirective(buildStep);

    final lock = await _readLock(
      buildStep,
      orMissing: () {
        final models = declarations.models.map((m) => m.clazz.name).toList()
          ..sort();
        return CocoonBuildError(
          schemaChangedMessage(
            models.first,
            '$lockFileName is missing (models: ${models.join(', ')}); create '
            'it with `cocoon migrate` and add it to the build.yaml sources',
          ),
        );
      },
    );

    final diff = SchemaDiff.compute(
      lock,
      declarations.collections,
      declarations.embeddedDeclarations,
    );
    // Only this library's models and embedded classes are checked: a lock
    // entry belonging to another library's model is not "removed" from this
    // file's point of view. The whole-package diff is `cocoon migrate`'s job.
    for (final collection in diff.collections) {
      if (!collection.isEmpty) {
        throw CocoonBuildError(
          schemaChangedMessage(
            collection.declared.model,
            describeCollectionDiff(collection),
          ),
        );
      }
    }
    for (final embedded in diff.embedded) {
      if (!embedded.isEmpty) {
        throw CocoonBuildError(
          schemaChangedMessage(
            embedded.declared.name,
            describeEmbeddedDiff(embedded),
          ),
        );
      }
    }

    return emitPartBody(
      models: declarations.models,
      embedded: declarations.embedded,
      lock: lock,
    );
  }

  /// Fails with a clear message when the model file does not declare the
  /// part file this builder writes.
  Future<void> _requirePartDirective(BuildStep buildStep) async {
    final unit = await buildStep.resolver.compilationUnitFor(buildStep.inputId);
    final expected = _partFileName(buildStep.inputId.path);
    for (final directive in unit.directives) {
      if (directive is PartDirective) {
        final uri = directive.uri.stringValue;
        if (uri != null && (uri == expected || uri.endsWith('/$expected'))) {
          return;
        }
      }
    }
    throw CocoonBuildError(
      "Add `part '$expected';` to ${buildStep.inputId.path}: cocoon_generator "
      'emits the collection code there.',
    );
  }
}

/// `lib/models.dart` -> `models.cocoon.dart`.
String _partFileName(String path) {
  final name = path.substring(path.lastIndexOf('/') + 1);
  return '${name.substring(0, name.length - '.dart'.length)}.cocoon.dart';
}

/// The builder producing `lib/cocoon_schema.g.dart` from `cocoon.lock`.
///
/// The lock is the input, so the builder only runs when the lock exists: a
/// package without collections generates nothing. It builds from either
/// lock name (the legacy `cocoon.lock.json` still builds unconverted
/// packages) and refuses to guess when both exist.
class _CocoonSchemaVersionBuilder implements Builder {
  const _CocoonSchemaVersionBuilder();

  @override
  Map<String, List<String>> get buildExtensions => const {
    '^$lockFileName': ['lib/cocoon_schema.g.dart'],
    '^$legacyLockFileName': ['lib/cocoon_schema.g.dart'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final other = buildStep.inputId.path == lockFileName
        ? AssetId(buildStep.inputId.package, legacyLockFileName)
        : AssetId(buildStep.inputId.package, lockFileName);
    if (await buildStep.canRead(other)) {
      throw CocoonBuildError(_bothLockFilesMessage);
    }
    final text = await buildStep.readAsString(buildStep.inputId);
    final lock = buildStep.inputId.path == lockFileName
        ? parseLockYaml(text)
        : SchemaLock.parse(text);
    await _requireImplementedMigrations(buildStep);
    await buildStep.writeAsString(
      AssetId(buildStep.inputId.package, 'lib/cocoon_schema.g.dart'),
      '// GENERATED CODE - DO NOT MODIFY BY HAND\n'
      '// Generated by cocoon_generator from `$lockFileName`.\n'
      '\n'
      '/// The schema version of this package\'s Cocoon collections, from the\n'
      '/// committed `$lockFileName`.\n'
      '///\n'
      '/// Pass it to the storage engine when opening a database, so it can\n'
      '/// detect pending schema migrations.\n'
      'const cocoonSchemaVersion = ${lock.version};\n',
    );
  }

  /// Fails the build while any migration file still throws
  /// `UnimplementedError`: the generated conversion and backfill stubs must
  /// be implemented before the package builds against the new schema.
  Future<void> _requireImplementedMigrations(BuildStep buildStep) async {
    await for (final id in buildStep.findAssets(
      Glob('lib/cocoon_migrations/m*.dart'),
    )) {
      final source = await buildStep.readAsString(id);
      // Match the `throw`, not the bare class name: the generated file
      // header documents the gate itself and mentions `UnimplementedError`.
      if (source.contains('throw UnimplementedError')) {
        throw CocoonBuildError(
          'Cocoon migration ${id.path} still contains an unimplemented '
          'conversion or backfill: implement the `upgrade...`/`backfill...` '
          'functions in it, then run build_runner again.',
        );
      }
    }
  }
}
