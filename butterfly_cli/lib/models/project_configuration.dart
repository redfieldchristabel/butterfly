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
  final String version;
  @JsonKey(required: true)
  final bool useAuth;
  @JsonKey(required: true)
  final bool useCore;
  final bool useRouter;
  final String? userModelName;

  // TODO: Add router config

  ProjectConfiguration({
    required this.version,
    required this.useAuth,
    required this.useCore,
    required this.useRouter,
    this.userModelName,
  }) {
    assert(useAuth && userModelName != null);
    if (version.isEmpty) {
      throw ArgumentError.value(version, 'name', 'Cannot be empty.');
    }
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
