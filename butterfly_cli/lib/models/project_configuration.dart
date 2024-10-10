import 'package:json_annotation/json_annotation.dart';

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
  final String? userModelName;

  // TODO: Add router config

  ProjectConfiguration(
      {required this.version, required this.useAuth, this.userModelName}) {
    if (version.isEmpty) {
      throw ArgumentError.value(version, 'name', 'Cannot be empty.');
    }
  }

  factory ProjectConfiguration.fromJson(Map json) =>
      _$ProjectConfigurationFromJson(json);

  Map<String, dynamic> toJson() => _$ProjectConfigurationToJson(this);

  @override
  String toString() => 'Configuration: ${toJson()}';
}
