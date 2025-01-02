// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'project_configuration.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ProjectConfiguration _$ProjectConfigurationFromJson(Map json) => $checkedCreate(
      'ProjectConfiguration',
      json,
      ($checkedConvert) {
        $checkKeys(
          json,
          allowedKeys: const [
            'useAuth',
            'useCore',
            'useRouter',
            'userModelName'
          ],
          requiredKeys: const ['useAuth', 'useCore'],
        );
        final val = ProjectConfiguration(
          useAuth: $checkedConvert('useAuth', (v) => v as bool),
          useCore: $checkedConvert('useCore', (v) => v as bool),
          useRouter: $checkedConvert('useRouter', (v) => v as bool),
          userModelName: $checkedConvert('userModelName', (v) => v as String?),
        );
        return val;
      },
    );

Map<String, dynamic> _$ProjectConfigurationToJson(
        ProjectConfiguration instance) =>
    <String, dynamic>{
      'useAuth': instance.useAuth,
      'useCore': instance.useCore,
      'useRouter': instance.useRouter,
      'userModelName': instance.userModelName,
    };
