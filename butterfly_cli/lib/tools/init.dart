import 'dart:async';
import 'dart:io';

import 'package:butterfly_cli/di/setup_dependencies.dart';
import 'package:butterfly_cli/interfaces/interfaces.dart';
import 'package:butterfly_cli/models/project_configuration.dart';
import 'package:butterfly_cli/tools/base.dart';
import 'package:dart_mcp/client.dart';

class InitTool extends BaseTool {
  @override
  Tool get definition => Tool(
        name: 'init',
        description:
            'Initialize a Flutter project with butterfly project structure and services',
        inputSchema: ObjectSchema(
          description: 'Parameters for initializing butterfly project',
          properties: {
            'useCore': Schema.bool(
              description: 'Use Butterfly core (error handler, loader, etc.)',
            ),
            'useAuth': Schema.bool(
              description: 'Include authentication system',
            ),
            'userModelName': Schema.string(
              description:
                  'Custom user model name (required if useAuth is true, e.g. "Customer")',
            ),
            'useRouter': Schema.bool(
              description: 'Include router system',
            ),
            'routerType': Schema.string(
              description: 'Router package to use (goRouter or other)',
            ),
          },
        ),
      );

  @override
  FutureOr<CallToolResult> call(CallToolRequest request) {
    final args = request.arguments ?? <String, Object?>{};

    final useCore = args['useCore'] as bool? ?? true;
    final useAuth = args['useAuth'] as bool? ?? false;
    final userModelName = args['userModelName'] as String?;
    final useRouter = args['useRouter'] as bool? ?? false;
    final routerTypeRaw = (args['routerType'] as String? ?? 'goRouter').trim();

    if (useAuth && (userModelName == null || userModelName.trim().isEmpty)) {
      return CallToolResult(
        isError: true,
        content: [
          TextContent(
            text:
                '"userModelName" is required when useAuth is true.\n'
                'Pick a name other than "User" (reserved keyword), '
                'e.g. "Customer", "Employee", "Manager".',
          ),
        ],
      );
    }

    RouterType? routerType;
    if (useRouter) {
      switch (routerTypeRaw.toLowerCase()) {
        case 'gorouter':
          routerType = RouterType.goRouter;
        case 'other':
          routerType = RouterType.other;
        default:
          return CallToolResult(
            isError: true,
            content: [
              TextContent(
                text:
                    'Invalid routerType "$routerTypeRaw". '
                    'Must be "goRouter" or "other".',
              ),
            ],
          );
      }
    }

    getIt<IDirectoryService>().ensureRootDirectory();

    final pubspecService = getIt<IPubspecService>();
    final masonService = getIt<IMasonService>();
    final output = StringBuffer();
    output.writeln('Initializing butterfly project...');

    final config = ProjectConfiguration(
      useAuth: useAuth,
      useCore: useCore,
      useRouter: useRouter,
      userModelName: useAuth ? userModelName!.trim() : null,
      routerType: routerType,
    );

    _saveConfig(config);
    output.writeln('Configuration saved');

    getIt<IDirectoryService>().ensureLibFolder();

    if (config.useCore) {
      pubspecService.addButterflyDependency('core_management');
      output.writeln('Added core_management dependency');
      // These are async but fire-and-forget from the tool perspective
      masonService.generateCoreService();
      masonService.generateThemeService();
      output.writeln('Generated core and theme services');
    }

    if (config.useAuth) {
      pubspecService.addButterflyDependency('auth_management');
      output.writeln('Added auth_management dependency');
      masonService.generateAuthService();
      output.writeln('Generated auth service');
    }

    if (config.useRouter && config.routerType != RouterType.other) {
      pubspecService.addDependency('go_router');
      pubspecService.addDependency('build_runner', dev: true);
      pubspecService.addDependency('go_router_builder', dev: true);
      masonService.generateRouteFile(config.routerType!);
      output.writeln('Generated route file');
    }

    output.writeln('Butterfly project initialized successfully');
    return CallToolResult(content: [TextContent(text: output.toString())]);
  }

  void _saveConfig(ProjectConfiguration config) {
    final configFile = File('.butterfly_project.yaml');
    final json = config.toJson()
      ..['version'] = '0.0.0';
    final yaml = jsonToYaml(json);
    configFile.writeAsStringSync(yaml);
  }

  /// Converts a JSON-like map to a simple YAML string.
  /// JSON is valid YAML, but this produces cleaner human-readable output.
  String jsonToYaml(Map<String, dynamic> map) {
    final buffer = StringBuffer();
    for (final entry in map.entries) {
      final value = entry.value;
      if (value is String) {
        buffer.writeln('${entry.key}: "${value.replaceAll('"', '\\"')}"');
      } else if (value is bool) {
        buffer.writeln('${entry.key}: $value');
      } else if (value == null) {
        buffer.writeln('${entry.key}: null');
      } else {
        buffer.writeln('${entry.key}: $value');
      }
    }
    return buffer.toString();
  }
}
