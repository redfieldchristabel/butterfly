import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:butterfly_cli/extensions/command_helper.dart';
import 'package:butterfly_cli/interfaces/interfaces.dart';
import 'package:butterfly_cli/models/project_configuration.dart';

class InitCommand extends Command with ButterflyLogger {
  final IPubspecService _pubspecService;
  final IProjectConfigurationService _configService;
  final IMasonService _masonService;

  InitCommand(this._pubspecService, this._configService, this._masonService);

  @override
  String get description =>
      'Initializes a Flutter project for butterfly pattern.';

  @override
  bool get takesArguments => false;

  @override
  String get name => 'init';

  @override
  Future<void> run() async {
    ensureRoot();

    final config = _configService.create();

    info("Creating project Structure");
    ensureLibFolder();

    detail("Check if models directory exist");
    _checkAndCreateDirectory('models');
    _checkAndCreateDirectory('services');
    _checkAndCreateDirectory('screens');
    _checkAndCreateDirectory('widgets');

    info('Project structure created successfully');
    info('Creating initial files');

    if (config.useCore) {
      _pubspecService.addButterflyDependency("core_management");
      await _masonService.generateCoreService();
      await _masonService.generateThemeService();
    }

    if (config.useAuth) {
      _pubspecService.addButterflyDependency("auth_management");
      await _masonService.generateAuthService();
    }

    if (config.useRouter && config.routerType != RouterType.other) {
      await _pubspecService.addDependency('go_router');
      await _pubspecService.addDependency('build_runner', dev: true);
      await _pubspecService.addDependency('go_router_builder', dev: true);

      await _masonService.generateRouteFile(config.routerType!);
    }

    info('Initial files created successfully');
  }

  void _checkAndCreateDirectory(final String dirName) {
    final dir = Directory(dirName);
    if (!dir.existsSync()) {
      info("Directory not exist, creating");
      dir.createSync();
    }
  }
}
