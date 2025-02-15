import 'dart:io';

import 'package:butterfly_cli/extensions/command_helper.dart';
import 'package:butterfly_cli/models/project_configuration.dart';
import 'package:butterfly_cli/readable_exception.dart';
import 'package:butterfly_cli/services/framework.dart';
import 'package:checked_yaml/checked_yaml.dart';

class ProjectConfigurationService with ButterflyLogger {
  ProjectConfiguration? _configuration;
  final File _file = File('.butterfly_project.yaml');

  bool exists() {
    frameworkService.ensureRootDirectory();
    return _file.existsSync();
  }

  void ensureValid() {
    frameworkService.ensureRootDirectory();

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

    // pubspecService.ensureFlutter();
  }

  ProjectConfiguration get configuration {
    assert(_configuration != null,
        'ProjectConfigurationService.ensureValid() must be called first');
    return _configuration!;
  }

  ProjectConfiguration create([ProjectConfiguration? defaultValue]) {
    frameworkService.ensureRootDirectory();

    info('Butterfly Core help you handle Flutter project easily\n'
        'It will help you like manage error handler, loading mechanism, locking mechanism'
        'and so much more');

    // TODO: add a url to view what Butterfly core can help with

    final useCore = logger.confirm('Do your project need to use Butterfly core',
        defaultValue: true);

    final useAuth = logger.confirm('Do your project need to use auth',
        defaultValue: defaultValue?.useAuth ?? true);
    final String? userModelName;
    if (useAuth) {
      userModelName = _askUserModel(defaultValue?.userModelName);
    } else {
      userModelName = null;
    }

    final useRouter = logger.confirm(
        'Do your project need to use router system',
        defaultValue: defaultValue?.useRouter ?? true);
    RouterType? routerType;

    if (useRouter) {
      routerType = logger.chooseOne<RouterType>('Choose your router type',
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
    final String answer = logger.prompt(
        'What is the name of your user model?\n'
        'Cant use User because it is a reserved keyword\n'
        'Example : [Customer, Employee, Manager, etc...]',
        defaultValue: defaultValue);
    if (answer.isEmpty) {
      logger.alert('User model name cannot be empty');
      return _askUserModel(defaultValue);
    }
    return answer;
  }
}

final ProjectConfigurationService projectConfigurationService =
    ProjectConfigurationService();
