import 'package:butterfly_cli/models/model_gen_params.dart';
import 'package:butterfly_cli/models/project_configuration.dart';

abstract class IMasonService {
  Future<void> generateModel(ModelGenParams params);
  Future<void> generateImmutableModel(ModelGenParams params);
  Future<void> generateCoreService();
  Future<void> generateThemeService();
  Future<void> generateAuthService();
  Future<void> generateRouteFile(RouterType type);
}
