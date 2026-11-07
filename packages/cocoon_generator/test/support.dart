/// Test helpers for cocoon_generator: run the real `cocoonBuilder` over
/// in-memory model files with a test `cocoon.lock.json`.
///
/// build_test's analyzer only sees assets written into its in-memory
/// filesystem, so the real sources of `cocoon` and its dependency closure are
/// preloaded into it; that is what lets the test models import
/// `package:cocoon/cocoon.dart` and have `@Collection` resolve.
library;

import 'dart:convert';
import 'dart:isolate';

import 'package:build/build.dart';
import 'package:build_test/build_test.dart';
import 'package:cocoon_generator/builder.dart';
import 'package:glob/glob.dart';
import 'package:package_config/package_config.dart';

/// The packages whose real `lib/**.dart` sources the analyzer needs to
/// resolve a test model importing `package:cocoon/cocoon.dart`.
const _preloadedPackages = [
  'cocoon',
  'meta',
  'sqlite_async',
  'sqlite3',
  'ffi',
  'path',
  'async',
  'collection',
  'web',
];

final Future<Map<String, List<int>>> _preloaded = _readPackageSources();

Future<Map<String, List<int>>> _readPackageSources() async {
  final config = await loadPackageConfigUri((await Isolate.packageConfig)!);
  final reader = PackageAssetReader(config, 'cocoon_generator');
  final bytes = <String, List<int>>{};
  for (final package in _preloadedPackages) {
    await for (final id in reader.findAssets(
      Glob('lib/**/*.dart'),
      package: package,
    )) {
      bytes['$id'] = await reader.readAsBytes(id);
    }
  }
  return bytes;
}

/// A fresh in-memory filesystem holding the real package sources. A new one
/// per run, so builds never see each other's outputs.
Future<TestReaderWriter> _freshReaderWriter() async {
  final readerWriter = TestReaderWriter(rootPackage: 'a');
  for (final MapEntry(key: id, value: bytes) in (await _preloaded).entries) {
    readerWriter.testing.writeBytes(AssetId.parse(id), bytes);
  }
  return readerWriter;
}

/// One `@Collection` entry of a test lock: path, fields (name -> canonical
/// lock type) and indexes (field lists, `-` prefix for descending).
final class TestCollection {
  const TestCollection(this.path, this.fields, {this.indexes = const []});

  final String path;
  final Map<String, String> fields;
  final List<List<String>> indexes;
}

/// Builds `cocoon.lock.json` text. Fields are numbered 1..n in map order.
String lockText({
  int version = 1,
  Map<String, TestCollection> collections = const {},
  Map<String, Map<String, String>> embedded = const {},
}) {
  final json = <String, Object>{
    'format': 1,
    'version': version,
    'collections': {
      for (final MapEntry(key: model, value: collection) in collections.entries)
        model: {
          'path': collection.path,
          'fields': {
            for (final (index, MapEntry(key: name, value: type))
                in collection.fields.entries.indexed)
              name: {'number': index + 1, 'type': type},
          },
          'reserved': <int>[],
          'indexes': collection.indexes,
        },
    },
    if (embedded.isNotEmpty)
      'embedded': {
        for (final MapEntry(key: name, value: fields) in embedded.entries)
          name: {
            'fields': {
              for (final (index, MapEntry(key: field, value: type))
                  in fields.entries.indexed)
                field: {'number': index + 1, 'type': type},
            },
            'reserved': <int>[],
          },
      },
  };
  return '${const JsonEncoder.withIndent('  ').convert(json)}\n';
}

/// The outcome of one builder run over a test library.
final class BuildRun {
  BuildRun(this._result, this._outputId);

  final TestBuilderResult _result;
  final AssetId _outputId;

  /// Whether the build succeeded.
  bool get succeeded => _result.succeeded;

  /// Every error the build reported (CocoonBuildError messages land here).
  List<String> get errors => _result.errors.toList();

  /// The generated part file's code. Throws when there is none, so callers
  /// should check [succeeded] first.
  String get code => _result.readerWriter.testing.readString(_outputId);

  /// Whether the part file was written.
  bool get hasOutput => _result.outputs.contains(_outputId);
}

/// Runs the real `cocoonBuilder` on `lib/models.dart` containing [models],
/// with [lock] as the package's `cocoon.lock.json` (empty string = no lock).
/// [extraFiles] adds further assets, e.g. migration stub files under
/// `lib/cocoon_migrations/` (asset paths like `a|lib/cocoon_migrations/m.dart`).
Future<BuildRun> runCocoonBuilder(
  String models,
  String lock, [
  Map<String, String> extraFiles = const {},
]) async {
  final result = await testBuilder(
    cocoonBuilder(const BuilderOptions({})),
    {
      'a|lib/models.dart': models,
      if (lock != '') 'a|cocoon.lock.json': lock,
      ...extraFiles,
    },
    readerWriter: await _freshReaderWriter(),
    flattenOutput: true,
  );
  return BuildRun(result, AssetId('a', 'lib/models.cocoon.dart'));
}

/// Runs the schema-version builder on a `cocoon.lock.json` input and returns
/// the outcome; [BuildRun.code] reads the generated `lib/cocoon_schema.g.dart`
/// when the build succeeded. [extraFiles] adds further assets, e.g. migration
/// stub files under `lib/cocoon_migrations/` (asset paths like
/// `a|lib/cocoon_migrations/m.dart`).
Future<BuildRun> runSchemaVersionBuilder(
  String lock, [
  Map<String, String> extraFiles = const {},
]) async {
  final result = await testBuilder(
    cocoonSchemaVersionBuilder(const BuilderOptions({})),
    {'a|cocoon.lock.json': lock, ...extraFiles},
    readerWriter: await _freshReaderWriter(),
    flattenOutput: true,
  );
  return BuildRun(result, AssetId('a', 'lib/cocoon_schema.g.dart'));
}
