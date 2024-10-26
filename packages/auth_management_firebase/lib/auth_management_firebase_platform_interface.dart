import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'auth_management_firebase_method_channel.dart';

abstract class AuthManagementFirebasePlatform extends PlatformInterface {
  /// Constructs a AuthManagementFirebasePlatform.
  AuthManagementFirebasePlatform() : super(token: _token);

  static final Object _token = Object();

  static AuthManagementFirebasePlatform _instance = MethodChannelAuthManagementFirebase();

  /// The default instance of [AuthManagementFirebasePlatform] to use.
  ///
  /// Defaults to [MethodChannelAuthManagementFirebase].
  static AuthManagementFirebasePlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [AuthManagementFirebasePlatform] when
  /// they register themselves.
  static set instance(AuthManagementFirebasePlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
