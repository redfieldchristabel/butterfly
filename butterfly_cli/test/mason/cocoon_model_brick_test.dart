import 'dart:io';
import 'dart:isolate';

import 'package:mason/mason.dart';
import 'package:test/test.dart';

/// Renders the real `mason/cocoon_model` brick shipped with the repo, so a
/// broken template (bad mason lambda, wrong variable) fails here instead of
/// on a user's machine.
void main() {
  test('cocoon_model brick renders a starter @Collection model', () async {
    final tempDir = Directory.systemTemp.createTempSync('cocoon_model_brick');
    addTearDown(() => tempDir.deleteSync(recursive: true));

    // Resolve the brick relative to this package, not Directory.current:
    // other suites change the process-wide working directory.
    final libUri = await Isolate.resolvePackageUri(
        Uri.parse('package:butterfly_cli/readable_exception.dart'));
    final cliDir = File(libUri!.toFilePath()).parent.parent;
    final brickPath = '${cliDir.parent.path}/mason/cocoon_model';
    expect(Directory(brickPath).existsSync(), isTrue,
        reason: 'brick not found at $brickPath');

    final generator = await MasonGenerator.fromBrick(Brick.path(brickPath));
    final files = await generator.generate(
      DirectoryGeneratorTarget(tempDir),
      vars: <String, dynamic>{
        'name': 'Txn',
        'fileName': 'txn',
        'collectionPath': 'accounts/{accountId}/txns',
      },
    );

    expect(files, hasLength(1));
    expect(files.single.path, endsWith('txn.dart'));

    final content = File(files.single.path).readAsStringSync();
    expect(content, contains("import 'package:cocoon/cocoon.dart';"));
    expect(content, contains("part 'txn.cocoon.dart';"));
    expect(content,
        contains("@Collection('accounts/{accountId}/txns', indexes: [])"));
    expect(content, contains('class Txn {'));
    expect(content, contains('const Txn({required this.name});'));
    expect(content, contains('final String name;'));
    // The dartdoc tells the reader how to add an Index and @Mirrored().
    expect(content, contains('Index(['));
    expect(content, contains('@Mirrored()'));
  });
}
