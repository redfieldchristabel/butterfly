import 'dart:io';

import 'package:butterfly_cli/extensions/command_helper.dart';

class FrameworkService with ButterflyLogger {
  T askInput<T>({required String question}) {
    assert(T == String || T == int);
    print(question);
    final answer = stdin.readLineSync();

    return (T == int ? int.parse(answer!) : answer) as T;
  }


  /// {@template ensureRootDirectory}
  /// Ensure current working directory are at root of the project.
  ///
  /// This method will search up until find file named `pubspec.yaml` and
  /// directory named `lib` in same directory.
  ///
  /// If not found in the working directory, it will go up one directory and
  /// try again. This will be continued until it reach the root directory.
  /// {@endtemplate}
  void ensureRootDirectory() {
    info('Ensure current working directory are at root of the project');
    var current = Directory.current;
    while (true) {
      if (File('${current.path}/pubspec.yaml').existsSync() &&
          Directory('${current.path}/lib').existsSync()) {
        Directory.current = current;
        alert('Set $current as working directory');
        break;
      }
      if (current.path == '/') {
        // TODO: change to throw
        logger.err('Unable to find root directory of the project');
        exit(1);
      }
      info('Current directory seem to not be root project\'s directory');
      current = current.parent;
      info('Trying $current directory');
    }
    info('Found project\'s root directory');
  }
}

final FrameworkService frameworkService = FrameworkService();
