import 'package:butterfly_cli/models/project_configuration.dart';

abstract class IProjectConfigurationService {
  bool exists();
  void ensureValid();
  ProjectConfiguration get configuration;
  ProjectConfiguration create([ProjectConfiguration? defaultValue]);
}
