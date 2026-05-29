abstract class IDirectoryService {
  void ensureRootDirectory();
  void ensureLibFolder();
  void ensureFlutterProject();
  void changeWorkingDirectory(String dir);
  bool get directoryIsRoot;
  set directoryIsRoot(bool value);
}
