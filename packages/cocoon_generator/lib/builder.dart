/// The build_runner entry points of cocoon_generator.
///
/// * `cocoonBuilder` generates a `*.cocoon.dart` part file for every library
///   with `@Collection` models (declare the part in the model file).
/// * `cocoonSchemaVersionBuilder` emits `lib/cocoon_schema.g.dart` with the
///   package's `cocoonSchemaVersion` constant, from the committed
///   `cocoon.lock.json`.
///
/// The builder never writes `cocoon.lock.json`; when models and lock
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

    final lockId = AssetId(buildStep.inputId.package, 'cocoon.lock.json');
    if (!await buildStep.canRead(lockId)) {
      final models = declarations.models.map((m) => m.clazz.name).toList()
        ..sort();
      throw CocoonBuildError(
        schemaChangedMessage(
          models.first,
          'cocoon.lock.json is missing (models: ${models.join(', ')}); create '
          'it with `cocoon migrate` and add it to the build.yaml sources',
        ),
      );
    }
    final lock = SchemaLock.parse(await buildStep.readAsString(lockId));

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

/// The builder producing `lib/cocoon_schema.g.dart` from `cocoon.lock.json`.
///
/// The lock is the input, so the builder only runs when the lock exists: a
/// package without collections generates nothing.
class _CocoonSchemaVersionBuilder implements Builder {
  const _CocoonSchemaVersionBuilder();

  @override
  Map<String, List<String>> get buildExtensions => const {
    '^cocoon.lock.json': ['lib/cocoon_schema.g.dart'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final lock = SchemaLock.parse(
      await buildStep.readAsString(buildStep.inputId),
    );
    await _requireImplementedMigrations(buildStep);
    await buildStep.writeAsString(
      AssetId(buildStep.inputId.package, 'lib/cocoon_schema.g.dart'),
      '// GENERATED CODE - DO NOT MODIFY BY HAND\n'
      '// Generated by cocoon_generator from `cocoon.lock.json`.\n'
      '\n'
      '/// The schema version of this package\'s Cocoon collections, from the\n'
      '/// committed `cocoon.lock.json`.\n'
      '///\n'
      '/// Pass it to the storage engine when opening a database, so it can\n'
      '/// detect pending schema migrations.\n'
      'const cocoonSchemaVersion = ${lock.version};\n',
    );
  }

  /// Fails the build while any migration file still throws
  /// `UnimplementedError`: the generated conversion stubs must be
  /// implemented before the package builds against the new schema.
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
          'conversion: implement the `upgrade...` functions in it, then run '
          'build_runner again.',
        );
      }
    }
  }
}
