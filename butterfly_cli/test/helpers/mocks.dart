import 'package:butterfly_cli/interfaces/interfaces.dart';
import 'package:butterfly_cli/models/model_gen_params.dart';
import 'package:butterfly_cli/models/project_configuration.dart';
import 'package:pub_semver/pub_semver.dart';

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
  T chooseOne<T>(String message, {required List<T> choices, T? defaultValue, String Function(T)? display}) {
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
  @override
  Version get version => Version.parse('1.0.0');

  @override
  Future<void> addDependency(String name, {bool dev = false}) async {}

  @override
  void addButterflyDependency(String name) {}
}

class MockMasonService implements IMasonService {
  @override
  Future<void> generateModel(ModelGenParams params) async {}

  @override
  Future<void> generateImmutableModel(ModelGenParams params) async {}

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
    _config = defaultValue ?? ProjectConfiguration(
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
