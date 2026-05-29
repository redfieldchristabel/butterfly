import 'package:butterfly_cli/commands/commit.dart';
import 'package:butterfly_cli/commands/generators/index.dart';
import 'package:butterfly_cli/commands/init.dart';
import 'package:butterfly_cli/commands/version.dart';
import 'package:butterfly_cli/interfaces/interfaces.dart';
import 'package:butterfly_cli/services/framework.dart';
import 'package:butterfly_cli/services/logger_service_impl.dart';
import 'package:butterfly_cli/services/mason.dart';
import 'package:butterfly_cli/services/project_configuration.dart';
import 'package:butterfly_cli/services/pubspec.dart';
import 'package:get_it/get_it.dart';

final getIt = GetIt.instance;

void configureDependencies() {
  final loggerService = LoggerServiceImpl();
  getIt.registerSingleton<ILoggerService>(loggerService);

  final directoryService = FrameworkService(loggerService);
  getIt.registerSingleton<IDirectoryService>(directoryService);

  final pubspecService = PubspecService(loggerService, directoryService);
  getIt.registerSingleton<IPubspecService>(pubspecService);

  final masonService = MasonService(loggerService);
  getIt.registerSingleton<IMasonService>(masonService);

  final configService =
      ProjectConfigurationService(loggerService, directoryService);
  getIt.registerSingleton<IProjectConfigurationService>(configService);

  // Commands (use ButterflyLogger mixin — resolves from GetIt internally)
  getIt.registerSingleton<VersionCommand>(VersionCommand());
  getIt.registerSingleton<CommitCommand>(CommitCommand());
  getIt.registerSingleton<GenerateCommand>(
      GenerateCommand(masonService, pubspecService));
  getIt.registerSingleton<InitCommand>(
      InitCommand(pubspecService, configService, masonService));
}
