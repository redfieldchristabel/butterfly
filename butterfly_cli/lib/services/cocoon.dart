import 'dart:io';

import 'package:butterfly_cli/interfaces/interfaces.dart';
import 'package:butterfly_cli/models/cocoon_model_gen_params.dart';
import 'package:butterfly_cli/readable_exception.dart';
import 'package:recase/recase.dart';

/// Scaffolds Cocoon `@Collection` models and delegates to the project's own
/// codegen tools.
///
/// The CLI never generates adapters or diffs schemas: a scaffold is a
/// template file, and everything else runs through
/// `dart run cocoon_generator:migrate` / `dart run build_runner build -d`
/// in the project root, so the project's pinned `cocoon_generator` version
/// always wins over whatever the CLI ships with.
class CocoonService implements ICocoonService {
  final ILoggerService _logger;
  final IPubspecService _pubspecService;
  final IMasonService _masonService;
  final IProcessRunner _processRunner;

  CocoonService(this._logger, this._pubspecService, this._masonService,
      this._processRunner);

  @override
  String defaultCollectionPath(String className) =>
      _pluralize(className.snakeCase);

  @override
  String? dependencyHint() {
    final missingTools = <String>[
      if (!_pubspecService.hasDependency('cocoon_generator'))
        'cocoon_generator',
      if (!_pubspecService.hasDependency('build_runner')) 'build_runner',
    ];
    final missingCocoon = !_pubspecService.hasDependency('cocoon');
    if (missingTools.isEmpty && !missingCocoon) return null;

    return [
      if (missingCocoon) 'dart pub add cocoon',
      if (missingTools.isNotEmpty)
        'dart pub add --dev cocoon_generator build_runner',
    ].join('\n');
  }

  @override
  void ensureDependencies() {
    final hint = dependencyHint();
    if (hint == null) return;

    throw ReadableException(
      title: 'Cocoon codegen dependencies missing',
      code: 66,
      message: "This project's pubspec.yaml is missing the Cocoon codegen "
          'tools. The CLI only delegates — the project runs its own '
          'generator.',
      hint: hint,
    );
  }

  @override
  Future<File> scaffoldModel({
    required String className,
    String? path,
    String? collection,
    bool overwrite = false,
  }) async {
    final pathRecase = ReCase(path ?? '');
    final classNameRecase = ReCase(className);

    // Same file naming as `generate model` without --cocoon: strip a path
    // prefix repeated in the class name (AuthUser + path auth -> user.dart).
    var fileName = className.snakeCase;
    if (path != null && className.startsWith(path.snakeCase)) {
      fileName = className.substring(path.length).trim();
    }
    if (path != null &&
        classNameRecase.pascalCase.startsWith(pathRecase.pascalCase)) {
      fileName = classNameRecase.pascalCase
          .substring(pathRecase.pascalCase.length)
          .trim();
      if (fileName.isEmpty) {
        throw ReadableException(
          title: 'Invalid class name',
          code: 66,
          message: 'Model name cannot be the same as the path',
          hint: 'Please provide a valid class name or remove the path',
        );
      }
    }
    fileName = fileName.snakeCase;

    final collectionPath = collection ?? defaultCollectionPath(className);

    final directory = Directory(
        '${Directory.current.path}/lib/models/${pathRecase.snakeCase}');

    final params = CocoonModelGenParams(
      name: className,
      path: directory,
      fileName: fileName,
      collectionPath: collectionPath,
    );

    await _masonService.generateCocoonModel(params, overwrite: overwrite);

    return File('${directory.path}/$fileName.dart');
  }

  @override
  Future<int> migrate([List<String> args = const []]) {
    ensureDependencies();
    _logger.detail(
        'Running dart run cocoon_generator:migrate with inherited stdio');
    return _processRunner
        .runInherited('dart', ['run', 'cocoon_generator:migrate', ...args]);
  }

  @override
  Future<int> build() {
    ensureDependencies();
    _logger.detail('Running dart run build_runner build -d');
    return _processRunner
        .runInherited('dart', ['run', 'build_runner', 'build', '-d']);
  }

  /// A plain-English plural for collection ids: `txns`, `categories`,
  /// `boxes`, `days`, `addresses`.
  String _pluralize(String word) {
    if (word.isEmpty) return word;
    final lower = word.toLowerCase();
    const sibilantEndings = ['s', 'x', 'z', 'ch', 'sh'];
    for (final ending in sibilantEndings) {
      if (lower.endsWith(ending)) return '${word}es';
    }
    if (lower.endsWith('y') &&
        word.length >= 2 &&
        !'aeiou'.contains(lower[word.length - 2])) {
      return '${word.substring(0, word.length - 1)}ies';
    }
    return '${word}s';
  }
}
