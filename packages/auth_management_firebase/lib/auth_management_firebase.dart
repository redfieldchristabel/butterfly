
import 'auth_management_firebase_platform_interface.dart';

class AuthManagementFirebase {
  Future<String?> getPlatformVersion() {
    return AuthManagementFirebasePlatform.instance.getPlatformVersion();
  }
}
