import 'dart:io';

import 'package:butterfly_cli/interfaces/interfaces.dart';
import 'package:butterfly_cli/models/project_configuration.dart';
import 'package:butterfly_cli/readable_exception.dart';
import 'package:checked_yaml/checked_yaml.dart';

class ProjectConfigurationService implements IProjectConfigurationService {
  final ILoggerService _logger;
  final IDirectoryService _directoryService;
  ProjectConfiguration? _configuration;
  final File _file = File('.butterfly_project.yaml');

  ProjectConfigurationService(this._logger, this._directoryService);

  @override
  bool exists() {
    _directoryService.ensureRootDirectory();
    return _file.existsSync();
  }

  @override
  void ensureValid() {
    _directoryService.ensureRootDirectory();

    if (!exists()) {
      throw ReadableException(
          title: 'Configuration file not found',
          message: 'Configuration file not found on ${_file.path}',
          code: 66,
          hint: 'Please run `butterfly init` first');
    }

    var configContent = _file.readAsStringSync();

    final configuration = checkedYamlDecode<ProjectConfiguration>(
      configContent,
      (m) => ProjectConfiguration.fromJson(m!),
      sourceUrl: Uri.parse(_file.path),
    );

    _configuration = configuration;
  }

  @override
  ProjectConfiguration get configuration {
    assert(_configuration != null,
        'ProjectConfigurationService.ensureValid() must be called first');
    return _configuration!;
  }

  @override
  ProjectConfiguration create([ProjectConfiguration? defaultValue]) {
    _directoryService.ensureRootDirectory();

    _logger.info('Butterfly Core help you handle Flutter project easily\n'
        'It will help you like manage error handler, loading mechanism, locking mechanism'
        'and so much more');

    final useCore = _logger.confirm('Do your project need to use Butterfly core',
        defaultValue: true);

    final useAuth = _logger.confirm('Do your project need to use auth',
        defaultValue: defaultValue?.useAuth ?? true);
    final String? userModelName;
    if (useAuth) {
      userModelName = _askUserModel(defaultValue?.userModelName);
    } else {
      userModelName = null;
    }

    final useRouter = _logger.confirm(
        'Do your project need to use router system',
        defaultValue: defaultValue?.useRouter ?? true);
    RouterType? routerType;

    if (useRouter) {
      routerType = _logger.chooseOne<RouterType>('Choose your router type',
          choices: RouterType.values,
          defaultValue: defaultValue?.routerType ?? RouterType.goRouter);
    }

    final ProjectConfiguration configuration = ProjectConfiguration(
        useAuth: useAuth,
        useCore: useCore,
        useRouter: useRouter,
        userModelName: userModelName,
        routerType: routerType);

    _configuration = configuration;

    return configuration;
  }

  String _askUserModel(String? defaultValue) {
    final String answer = _logger.prompt(
        'What is the name of your user model?\n'
        'Cant use User because it is a reserved keyword\n'
        'Example : [Customer, Employee, Manager, etc...]',
        defaultValue: defaultValue) ??
        '';
    if (answer.isEmpty) {
      _logger.alert('User model name cannot be empty');
      return _askUserModel(defaultValue);
    }
    return answer;
  }
}
