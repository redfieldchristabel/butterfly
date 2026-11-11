import 'dart:io';

/// The Cocoon tooling shortcuts of the CLI.
///
/// Implementations only scaffold a starter `@Collection` model from a
/// template and delegate to the project's own `build_runner` /
/// `cocoon_generator:migrate`; no generation or diff logic lives here, so the
/// CLI can be one version behind the project's Cocoon without mismatch.
abstract class ICocoonService {
  /// The default collection path for [className]: the plural snake_case of
  /// the name (`Txn` -> `txns`, `Category` -> `categories`).
  String defaultCollectionPath(String className);

  /// The `dart pub add` lines for the Cocoon dependencies missing from the
  /// project's pubspec.yaml (`cocoon`, `cocoon_generator`, `build_runner`),
  /// or `null` when everything needed is present.
  ///
  /// Callers must already be at the project root (`ensureRoot()`).
  String? dependencyHint();

  /// Throws a [ReadableException] listing the missing `dart pub add` lines
  /// when [dependencyHint] is not null.
  void ensureDependencies();

  /// Scaffolds a `@Collection` model file under
  /// `lib/models/<path>/<fileName>.dart` through the `cocoon_model` mason
  /// brick and returns the written file.
  ///
  /// [collection] is the collection path written as-is (`{param}` segments
  /// allowed); when null, [defaultCollectionPath] is used. Throws
  /// [FileAlreadyExistsException] when the target exists and [overwrite] is
  /// false. Callers must already be at the project root.
  Future<File> scaffoldModel({
    required String className,
    String? path,
    String? collection,
    bool overwrite = false,
  });

  /// Runs `dart run cocoon_generator:migrate [args]` in the project root
  /// with inherited stdio and returns its exit code unchanged (0 up to date
  /// or written, 1 refused/aborted/`--check` would change, 2 usage error).
  Future<int> migrate([List<String> args = const []]);

  /// Runs `dart run cocoon_generator:index add [args]` in the project root
  /// with inherited stdio and returns its exit code unchanged (0 added or
  /// already declared, 1 refused/not found, 2 usage error). [args] starts
  /// after `add`: the model name and the comma-separated fields.
  Future<int> indexAdd([List<String> args = const []]);

  /// Runs `dart run build_runner build -d` in the project root with
  /// inherited stdio and returns its exit code.
  Future<int> build();
}
