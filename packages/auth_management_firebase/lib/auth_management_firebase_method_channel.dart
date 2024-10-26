import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'auth_management_firebase_platform_interface.dart';

/// An implementation of [AuthManagementFirebasePlatform] that uses method channels.
class MethodChannelAuthManagementFirebase extends AuthManagementFirebasePlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('auth_management_firebase');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
