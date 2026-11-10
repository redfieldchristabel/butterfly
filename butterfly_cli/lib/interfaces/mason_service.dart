import 'package:butterfly_cli/models/cocoon_model_gen_params.dart';
import 'package:butterfly_cli/models/model_gen_params.dart';
import 'package:butterfly_cli/models/project_configuration.dart';

abstract class IMasonService {
  Future<void> generateModel(ModelGenParams params, {bool overwrite = false});
  Future<void> generateImmutableModel(ModelGenParams params,
      {bool overwrite = false});

  /// Generates the `@Collection` model scaffold through the `cocoon_model`
  /// brick: the template only, the project's own build_runner does the rest.
  Future<void> generateCocoonModel(CocoonModelGenParams params,
      {bool overwrite = false});
  Future<void> generateCoreService();
  Future<void> generateThemeService();
  Future<void> generateAuthService();
  Future<void> generateRouteFile(RouterType type);
}
