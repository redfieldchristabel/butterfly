import 'package:butterfly_cli/models/model_gen_params.dart';
import 'package:butterfly_cli/models/project_configuration.dart';

abstract class IMasonService {
  Future<void> generateModel(ModelGenParams params, {bool overwrite = false});
  Future<void> generateImmutableModel(ModelGenParams params,
      {bool overwrite = false});
  Future<void> generateCoreService();
  Future<void> generateThemeService();
  Future<void> generateAuthService();
  Future<void> generateRouteFile(RouterType type);
}
