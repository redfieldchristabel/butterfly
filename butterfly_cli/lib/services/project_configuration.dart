import 'dart:io';

import 'package:butterfly_cli/extensions/command_helper.dart';
import 'package:butterfly_cli/models/project_configuration.dart';
import 'package:butterfly_cli/services/framework.dart';
import 'package:checked_yaml/checked_yaml.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:yaml_edit/yaml_edit.dart';

class ProjectConfigurationService with ButterflyLogger {
  ProjectConfiguration? _configuration;

  bool exists() {
    frameworkService.ensureRootDirectory();
    return File('pubspec.yaml').existsSync();
  }

  void ensureValid() {
    frameworkService.ensureRootDirectory();

    if (!exists()) {
      throw Exception('Unable to find project configuration');
    }

    var configFile = File('butterfly_project.yaml');
    var configContent = configFile.readAsStringSync();

    final configuration = checkedYamlDecode<ProjectConfiguration>(
      configContent,
      (m) => ProjectConfiguration.fromJson(m!),
      sourceUrl: Uri.parse(configFile.path),
    );

    _configuration = configuration;
  }

  ProjectConfiguration get configuration {
    assert(_configuration != null,
        'ProjectConfigurationService.ensureValid() must be called first');
    return _configuration!;
  }

  Future<void> init() async {
    frameworkService.ensureRootDirectory();

    PackageInfo packageInfo = await PackageInfo.fromPlatform();
    final useAuth =
        logger.confirm('Do your project need to use auth', defaultValue: true);
    final String? userModelName;
    if (useAuth) {
      userModelName = logger.prompt('What is the name of your user model?\n'
          'Cant use User because it is a reserved keyword\n'
          'Example : [Customer, Employee, Manager, etc...]');
    } else {
      userModelName = null;
    }

    final ProjectConfiguration configuration = ProjectConfiguration(
        version: packageInfo.version,
        useAuth: useAuth,
        userModelName: userModelName);

    _configuration = configuration;

    final configFile = File('butterfly_project.yaml');

    final editor = YamlEditor('');
    info('Compile project configuration to yaml');
    editor.update([], configuration.toJson());
    info('Writing project configuration to ${configFile.path}');
    configFile.writeAsStringSync(editor.toString());
    alert('Write project configuration to butterfly_project.yaml\n'
        'You can find it at ${configFile.path}');
  }
}

final ProjectConfigurationService projectConfigurationService =
    ProjectConfigurationService();
