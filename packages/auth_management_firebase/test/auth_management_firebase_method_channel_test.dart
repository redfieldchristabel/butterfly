import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:auth_management_firebase/auth_management_firebase_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MethodChannelAuthManagementFirebase platform = MethodChannelAuthManagementFirebase();
  const MethodChannel channel = MethodChannel('auth_management_firebase');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (MethodCall methodCall) async {
        return '42';
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('getPlatformVersion', () async {
    expect(await platform.getPlatformVersion(), '42');
  });
}
