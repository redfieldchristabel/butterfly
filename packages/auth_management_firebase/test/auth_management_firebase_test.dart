import 'package:flutter_test/flutter_test.dart';
import 'package:auth_management_firebase/auth_management_firebase.dart';
import 'package:auth_management_firebase/auth_management_firebase_platform_interface.dart';
import 'package:auth_management_firebase/auth_management_firebase_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockAuthManagementFirebasePlatform
    with MockPlatformInterfaceMixin
    implements AuthManagementFirebasePlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final AuthManagementFirebasePlatform initialPlatform = AuthManagementFirebasePlatform.instance;

  test('$MethodChannelAuthManagementFirebase is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelAuthManagementFirebase>());
  });

  test('getPlatformVersion', () async {
    AuthManagementFirebase authManagementFirebasePlugin = AuthManagementFirebase();
    MockAuthManagementFirebasePlatform fakePlatform = MockAuthManagementFirebasePlatform();
    AuthManagementFirebasePlatform.instance = fakePlatform;

    expect(await authManagementFirebasePlugin.getPlatformVersion(), '42');
  });
}
