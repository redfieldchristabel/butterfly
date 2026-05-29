import 'package:pub_semver/pub_semver.dart';

abstract class IPubspecService {
  Version get version;
  Future<void> addDependency(String name, {bool dev = false});
  void addButterflyDependency(String name);
}
