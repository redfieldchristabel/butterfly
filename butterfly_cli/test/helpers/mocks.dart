import 'dart:io';

import 'package:butterfly_cli/interfaces/interfaces.dart';
import 'package:butterfly_cli/models/cocoon_model_gen_params.dart';
import 'package:butterfly_cli/models/model_gen_params.dart';
import 'package:butterfly_cli/models/project_configuration.dart';
import 'package:butterfly_cli/readable_exception.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:recase/recase.dart';

class MockLoggerService implements ILoggerService {
  @override
  void info(String? message) {}

  @override
  void detail(String? message) {}

  @override
  void err(String? message) {}

  @override
  void warn(String? message) {}

  @override
  void alert(String? message) {}

  @override
  String? prompt(String message, {String? defaultValue}) => defaultValue;

  @override
  bool confirm(String message, {bool defaultValue = true}) => defaultValue;

  @override
  T chooseOne<T>(String message,
      {required List<T> choices,
      T? defaultValue,
      String Function(T)? display}) {
    return defaultValue ?? choices.first;
  }
}

class MockDirectoryService implements IDirectoryService {
  @override
  bool directoryIsRoot = true;

  @override
  void changeWorkingDirectory(String dir) {}

  @override
  void ensureFlutterProject() {}

  @override
  void ensureLibFolder() {}

  @override
  void ensureRootDirectory() {}
}

class MockPubspecService implements IPubspecService {
  /// Dependency names reported present; defaults to the full Cocoon set so
  /// tests that don't care about dependencies never trip the checks.
  final Set<String> dependencies;

  MockPubspecService({Set<String>? dependencies})
      : dependencies =
            dependencies ?? {'cocoon', 'cocoon_generator', 'build_runner'};

  @override
  Version get version => Version.parse('1.0.0');

  @override
  Future<void> addDependency(String name, {bool dev = false}) async {}

  @override
  void addButterflyDependency(String name) {}

  @override
  bool hasDependency(String name) => dependencies.contains(name);
}

class RecordedCocoonModel {
  final CocoonModelGenParams params;
  final bool overwrite;
  RecordedCocoonModel(this.params, this.overwrite);
}

class MockMasonService implements IMasonService {
  final cocoonModels = <RecordedCocoonModel>[];
  final plainModels = <ModelGenParams>[];

  @override
  Future<void> generateModel(ModelGenParams params,
      {bool overwrite = false}) async {
    plainModels.add(params);
  }

  @override
  Future<void> generateImmutableModel(ModelGenParams params,
      {bool overwrite = false}) async {}

  @override
  Future<void> generateCocoonModel(CocoonModelGenParams params,
      {bool overwrite = false}) async {
    cocoonModels.add(RecordedCocoonModel(params, overwrite));
  }

  @override
  Future<void> generateCoreService() async {}

  @override
  Future<void> generateThemeService() async {}

  @override
  Future<void> generateAuthService() async {}

  @override
  Future<void> generateRouteFile(RouterType type) async {}
}

class MockProjectConfigurationService implements IProjectConfigurationService {
  ProjectConfiguration? _config;

  @override
  ProjectConfiguration create([ProjectConfiguration? defaultValue]) {
    _config = defaultValue ??
        ProjectConfiguration(
          useAuth: false,
          useCore: false,
          useRouter: false,
        );
    return _config!;
  }

  @override
  ProjectConfiguration get configuration => _config!;

  @override
  void ensureValid() {}

  @override
  bool exists() => true;
}

class RecordedProcessCall {
  final String executable;
  final List<String> arguments;
  final bool inheritedStdio;
  RecordedProcessCall(this.executable, this.arguments, this.inheritedStdio);
}

class MockProcessRunner implements IProcessRunner {
  final calls = <RecordedProcessCall>[];

  /// Exit code the next run reports.
  int nextExitCode = 0;

  /// Stdout/stderr the next captured run reports.
  String nextStdout = '';
  String nextStderr = '';

  @override
  Future<int> runInherited(String executable, List<String> arguments) async {
    calls.add(RecordedProcessCall(executable, arguments, true));
    return nextExitCode;
  }

  @override
  Future<CapturedProcess> runCaptured(
      String executable, List<String> arguments) async {
    calls.add(RecordedProcessCall(executable, arguments, false));
    return CapturedProcess(nextExitCode, nextStdout, nextStderr);
  }
}

class MockCocoonService implements ICocoonService {
  /// What [dependencyHint] returns (null = all dependencies present).
  String? hintToReturn;

  String? scaffoldedClassName;
  String? scaffoldedPath;
  String? scaffoldedCollection;
  bool? scaffoldedOverwrite;

  @override
  String defaultCollectionPath(String className) => 'txns';

  @override
  String? dependencyHint() => hintToReturn;

  @override
  void ensureDependencies() {
    final hint = dependencyHint();
    if (hint != null) {
      throw ReadableException(
        title: 'Cocoon codegen dependencies missing',
        code: 66,
        message: 'missing',
        hint: hint,
      );
    }
  }

  @override
  Future<File> scaffoldModel({
    required String className,
    String? path,
    String? collection,
    bool overwrite = false,
  }) async {
    scaffoldedClassName = className;
    scaffoldedPath = path;
    scaffoldedCollection = collection;
    scaffoldedOverwrite = overwrite;
    return File('unused/${className.snakeCase}.dart');
  }

  @override
  Future<int> migrate([List<String> args = const []]) async => 0;

  @override
  Future<int> indexAdd([List<String> args = const []]) async => 0;

  @override
  Future<int> build() async => 0;
}
