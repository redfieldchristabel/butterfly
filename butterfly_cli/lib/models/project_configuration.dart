import 'package:butterfly_cli/readable_exception.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:pub_semver/pub_semver.dart';

part 'project_configuration.g.dart';

@JsonSerializable(
  anyMap: true,
  checked: true,
  disallowUnrecognizedKeys: true,
)
class ProjectConfiguration {
  @JsonKey(required: true)
  final bool useAuth;
  @JsonKey(required: true)
  final bool useCore;
  final bool useRouter;
  final RouterType? routerType;
  final String? userModelName;

  // TODO: Add router config

  ProjectConfiguration({
    required this.useAuth,
    required this.useCore,
    required this.useRouter,
    this.routerType,
    this.userModelName,
  }) {
    assert(useAuth && userModelName != null);
  }

  factory ProjectConfiguration.fromJson(Map json) {
    final Version version = Version.parse(json['version'] as String);

    // TODO: add a new version to support backward config
    switch (version.major) {
      case 0:
        return _$ProjectConfigurationFromJson(json);

      default:
        throw ReadableException(
            title: 'Fail to parse butterfly project configuration',
            message: 'Cant find match version',
            code: 66);
    }
  }

  Map<String, dynamic> toJson() => _$ProjectConfigurationToJson(this);

  @override
  String toString() => 'Configuration: ${toJson()}';
}

enum RouterType {
  goRouter,
  other
}
