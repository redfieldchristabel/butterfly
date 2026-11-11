/// `dart run cocoon_generator:index add <Model> <fields>`: the one-line fix
/// a `MissingIndexException` names.
///
/// Locates the `@Collection` class `<Model>` in the package (the analyzer,
/// exactly like `migrate`), validates every field and path-param name, and
/// edits the model's source: a one-field index over a model field becomes
/// `@Indexed()` (or `@Indexed(descending: true)`) on that field; everything
/// else — composites and path params — appends `Index([...])` to the
/// `@Collection(indexes: [...])` list, creating the named argument when it is
/// missing. The edited file is `dart format`ed, and the command prints the
/// two follow-up commands (`migrate`, then `build_runner`). It is a
/// development tool like `migrate`, never a CI step.
///
/// Narrow edits only: an `indexes:` list the command does not fully
/// understand (a spread, a const variable, a non-literal part) or a field
/// carrying another `@Indexed()` is refused with exit code 1 and the exact
/// `Index([...])` text to paste by hand.
///
/// The whole flow is injectable for tests: [runIndexAdd] takes the package
/// root and an injectable [MigrateIo] terminal, the same way `runMigrate`
/// does.
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:cocoon/cocoon.dart' show nameSimilarity;
import 'package:source_gen/source_gen.dart';

import 'extract.dart' show CocoonBuildError, ExtractedModel, extractLibrary;
import 'migrate_cli.dart' show MigrateException, MigrateIo, findPackageRoot;

/// Exit code 0: the index was added, or an identical one already declared it.
const _exitOk = 0;

/// Exit code 1: refused (unknown name, unsupported annotation shape) or the
/// model was not found.
const _exitAborted = 1;

/// Exit code 2: usage error.
const _exitUsage = 2;

/// The usage line the command prints for wrong arguments.
const _usage =
    'Usage: dart run cocoon_generator:index add <Model> <fields>\n'
    '  fields: comma list in index order, `-` prefixing a descending part,\n'
    '  e.g. `Txn accountId,-bookedOn` or `Account name`';

/// A failure the index command reports to the user.
final class IndexAddException implements Exception {
  /// Builds a failure with the process exit code it maps to.
  IndexAddException(this.message, {this.exitCode = _exitAborted});

  /// The message printed.
  final String message;

  /// The process exit code: 1 for refusals, 2 for usage errors.
  final int exitCode;

  @override
  String toString() => message;
}

final class _StdIndexIo implements MigrateIo {
  @override
  bool get stdinIsTerminal => stdin.hasTerminal;

  @override
  bool get stdoutIsTerminal => stdout.hasTerminal;

  @override
  String readLine() => stdin.readLineSync() ?? '';

  @override
  void write(String text) => stdout.write(text);

  @override
  void writeError(String text) => stderr.write(text);
}

/// What the command found and is about to edit.
typedef _Target = ({
  ExtractedModel model,
  ResolvedUnitResult unit,
  String filePath,
});

/// The `name` of an index part, without its descending `-` prefix.
String _baseName(String part) =>
    part.startsWith('-') ? part.substring(1) : part;

/// The `Index([...])` source for [parts] (`-` prefixing a descending part):
/// both the declaration the class-level edit writes and the paste text the
/// refusals print.
String indexDeclarationSource(List<String> parts) =>
    "Index([${parts.map((part) => "'$part'").join(', ')}])";

/// Runs the `index add` command over the package containing [packageRoot]
/// (default: the working directory, walking up to the nearest
/// `pubspec.yaml`). Returns the process exit code.
///
/// Exit codes: 0 when the index was added or already existed; 1 when the
/// model or a name was not found or the annotation is not a shape the
/// command edits; 2 for usage errors.
Future<int> runIndexAdd({
  String? packageRoot,
  List<String> args = const [],
  MigrateIo? io,
}) async {
  final terminal = io ?? _StdIndexIo();
  try {
    return await _run(packageRoot, args, terminal);
  } on IndexAddException catch (error) {
    terminal.writeError('${error.message}\n');
    return error.exitCode;
  } on MigrateException catch (error) {
    terminal.writeError('${error.message}\n');
    return error.exitCode;
  } on CocoonBuildError catch (error) {
    terminal.writeError('${error.message}\n');
    return _exitAborted;
  }
}

Future<int> _run(String? packageRoot, List<String> args, MigrateIo io) async {
  if (args.length != 3 || args.first != 'add') {
    throw IndexAddException(_usage, exitCode: _exitUsage);
  }
  final modelName = args[1];
  final parts = _parseParts(args[2]);

  final root = findPackageRoot(packageRoot);
  final libPath = '$root/lib';
  if (!Directory(libPath).existsSync()) {
    throw IndexAddException(
      'No lib/ directory under $root.',
      exitCode: _exitUsage,
    );
  }

  final target = await _findModel(libPath, modelName);
  if (target == null) {
    final declared = await _declaredModelNames(libPath);
    final suggestion = _didYouMean(modelName, declared);
    throw IndexAddException(
      'No @Collection class named "$modelName" under $libPath.\n'
      '${suggestion.isEmpty ? '' : '$suggestion\n'}'
      'Declared collections: '
      '${declared.isEmpty ? '(none)' : declared.join(', ')}',
    );
  }
  final extracted = target.model;
  final relative = _relativeTo(root, target.filePath);

  // Every part must name a field or a path param of the collection.
  final names = [
    for (final field in extracted.clazz.fields) field.name,
    ...extracted.params,
  ];
  for (final part in parts) {
    final name = _baseName(part);
    if (!names.contains(name)) {
      final suggestion = _didYouMean(name, names);
      throw IndexAddException(
        '$modelName has no field or path param named "$name".\n'
        '${suggestion.isEmpty ? '' : '$suggestion\n'}'
        'Fields and path params: ${names.join(', ')}',
      );
    }
  }

  // Idempotent: an index declared in exactly this order already serves it.
  for (final index in extracted.indexes) {
    if (!_fieldsEqual(index.fields, parts)) {
      continue;
    }
    final fieldDeclarer = extracted.clazz.fields
        .where((field) => field.indexed != null)
        .where((field) => _fieldsEqual(field.indexed!.fields, parts))
        .map((field) => '@Indexed() on ${field.name}')
        .firstOrNull;
    io.write(
      'Nothing to do: ${indexDeclarationSource(parts)} is already declared '
      'on $modelName '
      '${fieldDeclarer == null ? 'in @Collection(indexes: [...])' : 'by $fieldDeclarer'}.\n',
    );
    return _exitOk;
  }

  // One field that is not a path param -> the field annotation. Everything
  // else (composites, path params) -> the class-level composite.
  final newSource =
      parts.length == 1 && !extracted.params.contains(_baseName(parts.single))
      ? _addFieldAnnotation(
          target.unit,
          modelName: modelName,
          fieldName: _baseName(parts.single),
          descending: parts.single.startsWith('-'),
          pasteDeclaration: indexDeclarationSource(parts),
        )
      : _appendToIndexesList(target.unit, modelName: modelName, parts: parts);
  if (newSource == null) {
    throw IndexAddException(
      _unsupportedShapeMessage(modelName, relative, parts),
    );
  }
  File(target.filePath).writeAsStringSync(newSource);
  final formatted = await _dartFormat(target.filePath);
  if (formatted.isNotEmpty) {
    io.writeError(formatted);
  }
  io.write(
    'Added ${indexDeclarationSource(parts)} to $modelName in $relative '
    '(dart format applied).\n'
    '\n'
    'Next:\n'
    '  dart run cocoon_generator:migrate\n'
    '      (an index on an existing collection changes the lock version)\n'
    '  dart run build_runner build -d\n',
  );
  return _exitOk;
}

List<String> _parseParts(String argument) {
  final rawParts = argument.split(',');
  if (rawParts.any((part) => part.trim().isEmpty)) {
    throw IndexAddException(_usage, exitCode: _exitUsage);
  }
  final parts = [for (final part in rawParts) part.trim()];
  final pattern = RegExp(r'^-?[a-zA-Z][a-zA-Z0-9_]*$');
  for (final part in parts) {
    if (!pattern.hasMatch(part)) {
      throw IndexAddException(
        'Index parts must be field or path-param names, `-` prefixing a '
        'descending part; got "$part".\n$_usage',
        exitCode: _exitUsage,
      );
    }
  }
  if (parts.toSet().length != parts.length) {
    throw IndexAddException(
      'The same field appears twice in "$argument".\n$_usage',
      exitCode: _exitUsage,
    );
  }
  return parts;
}

/// Finds the `@Collection` class [modelName] under [libPath] with the
/// analyzer, exactly like `migrate` does, and the resolved unit that holds
/// its declaration. `null` when no such class exists.
Future<_Target?> _findModel(String libPath, String modelName) async {
  final contexts = AnalysisContextCollection(includedPaths: [libPath]);
  final matches = <_Target>[];
  for (final context in contexts.contexts) {
    for (final filePath in context.contextRoot.analyzedFiles()) {
      if (!filePath.endsWith('.dart')) {
        continue;
      }
      final session = context.currentSession;
      final libraryResult = await session.getResolvedLibrary(filePath);
      if (libraryResult is! ResolvedLibraryResult) {
        continue;
      }
      final declarations = extractLibrary(LibraryReader(libraryResult.element));
      final extracted = declarations?.models
          .where((model) => model.clazz.name == modelName)
          .firstOrNull;
      if (extracted == null) {
        continue;
      }
      // The class declaration lives in the library's defining unit or one of
      // its parts; resolve each and find the class node.
      for (final fragment in libraryResult.element.fragments) {
        final unitPath = fragment.source.fullName;
        final unitResult = await session.getResolvedUnit(unitPath);
        if (unitResult is! ResolvedUnitResult) {
          continue;
        }
        for (final declaration
            in unitResult.unit.declarations.whereType<ClassDeclaration>()) {
          if (declaration.namePart.typeName.lexeme != modelName) {
            continue;
          }
          matches.add((model: extracted, unit: unitResult, filePath: unitPath));
        }
      }
    }
  }
  if (matches.length > 1) {
    final paths = {
      for (final match in matches) _relativeTo('.', match.filePath),
    };
    throw IndexAddException(
      'Model $modelName is declared more than once (${paths.join(', ')}); '
      'one name must be one collection.',
    );
  }
  return matches.firstOrNull;
}

/// The names of every `@Collection` class under [libPath], for the error when
/// the requested model does not exist.
Future<List<String>> _declaredModelNames(String libPath) async {
  final names = <String>{};
  final contexts = AnalysisContextCollection(includedPaths: [libPath]);
  for (final context in contexts.contexts) {
    for (final filePath in context.contextRoot.analyzedFiles()) {
      if (!filePath.endsWith('.dart')) {
        continue;
      }
      final result = await context.currentSession.getResolvedLibrary(filePath);
      if (result is! ResolvedLibraryResult) {
        continue;
      }
      final declarations = extractLibrary(LibraryReader(result.element));
      if (declarations != null) {
        names.addAll([
          for (final model in declarations.models) model.clazz.name,
        ]);
      }
    }
  }
  return names.toList()..sort();
}

// -- Source edits -------------------------------------------------------------

/// Adds `@Indexed()` (or `@Indexed(descending: true)`) above [fieldName]'s
/// declaration in [unit]'s class [modelName]. Returns the new source, or
/// `null` when the declaration is not a shape the command edits (the field
/// is not a single-variable declaration, or it already carries `@Indexed`).
String? _addFieldAnnotation(
  ResolvedUnitResult unit, {
  required String modelName,
  required String fieldName,
  required bool descending,
  required String pasteDeclaration,
}) {
  final clazz = _classDeclaration(unit, modelName);
  if (clazz == null) {
    return null;
  }
  for (final member in clazz.body.members) {
    if (member is! FieldDeclaration) {
      continue;
    }
    final variables = member.fields.variables;
    if (!variables.any((variable) => variable.name.lexeme == fieldName)) {
      continue;
    }
    if (variables.length > 1) {
      throw IndexAddException(
        'The field "$fieldName" of $modelName is declared together with '
        'others (${variables.map((v) => v.name.lexeme).join(', ')}); the '
        'command edits single-field declarations only.\n'
        '${_pasteAdvice(pasteDeclaration, modelName)}',
      );
    }
    if (member.metadata.any(
      (annotation) => _isCocoonAnnotation(annotation, 'Indexed'),
    )) {
      throw IndexAddException(
        'The field "$fieldName" of $modelName already carries @Indexed; '
        'edit it by hand, or paste $pasteDeclaration into '
        '@Collection(indexes: [...]) instead.',
      );
    }
    final source = unit.content;
    final insertAt = member.firstTokenAfterCommentAndMetadata.offset;
    final indent = _lineIndent(source, insertAt);
    final annotation = descending ? '@Indexed(descending: true)' : '@Indexed()';
    return source.replaceRange(insertAt, insertAt, '$annotation\n$indent');
  }
  throw IndexAddException(
    'The field "$fieldName" of $modelName is not a declared field of the '
    'class; the command annotates field declarations only.',
  );
}

/// Appends `Index([...])` to the `@Collection(indexes: [...])` list of
/// [modelName], creating the named argument when it is missing. Returns the
/// new source, or `null` when the annotation is not a shape the command
/// edits (a const-variable annotation, a spread, a non-literal part).
String? _appendToIndexesList(
  ResolvedUnitResult unit, {
  required String modelName,
  required List<String> parts,
}) {
  final clazz = _classDeclaration(unit, modelName);
  if (clazz == null) {
    return null;
  }
  final annotation = clazz.metadata
      .where((annotation) => _isCocoonAnnotation(annotation, 'Collection'))
      .firstOrNull;
  if (annotation == null || annotation.arguments == null) {
    return null;
  }
  final insertion = indexDeclarationSource(parts);
  final arguments = annotation.arguments!;
  final indexesArgument = arguments.arguments
      .whereType<NamedExpression>()
      .where((argument) => argument.name.label.name == 'indexes')
      .firstOrNull;
  final source = unit.content;
  if (indexesArgument == null) {
    // @Collection('path') -> @Collection('path', indexes: [Index([...])]).
    final insertAt = arguments.rightParenthesis.offset;
    return source.replaceRange(insertAt, insertAt, ', indexes: [$insertion]');
  }
  final list = indexesArgument.expression;
  if (list is! ListLiteral) {
    return null;
  }
  if (list.elements.isEmpty) {
    // indexes: [] -> indexes: [Index([...])].
    final insertAt = list.leftBracket.end;
    return source.replaceRange(insertAt, insertAt, insertion);
  }
  for (final element in list.elements) {
    if (element is! InstanceCreationExpression || !_isIndexLiteral(element)) {
      return null;
    }
  }
  // Append after the last element; dart format settles the layout.
  final insertAt = list.elements.last.end;
  return source.replaceRange(insertAt, insertAt, ', $insertion');
}

/// Whether [creation] is a resolved `Index(...)` invocation from cocoon.
bool _isIndexLiteral(InstanceCreationExpression creation) {
  final type = creation.constructorName.type.element;
  return type is ClassElement &&
      type.name == 'Index' &&
      type.library.uri.toString().startsWith('package:cocoon/');
}

/// Whether [annotation] resolves to cocoon's class [className] (its
/// generative constructor).
bool _isCocoonAnnotation(Annotation annotation, String className) {
  final element = annotation.element;
  return element is ConstructorElement &&
      element.enclosingElement.name == className &&
      element.library.uri.toString().startsWith('package:cocoon/');
}

ClassDeclaration? _classDeclaration(ResolvedUnitResult unit, String name) =>
    unit.unit.declarations
        .whereType<ClassDeclaration>()
        .where((declaration) => declaration.namePart.typeName.lexeme == name)
        .firstOrNull;

/// The whitespace between [offset]'s line start and [offset]: the indentation
/// a new annotation line above the declaration needs.
String _lineIndent(String source, int offset) {
  final lineStart = source.lastIndexOf('\n', offset - 1) + 1;
  final prefix = source.substring(lineStart, offset);
  final whitespace = RegExp(r'^\s*').firstMatch(prefix);
  return whitespace?.group(0) ?? '';
}

String _unsupportedShapeMessage(
  String modelName,
  String relativePath,
  List<String> parts,
) =>
    'The @Collection annotation of $modelName ($relativePath) is not a shape '
    'this command edits: the indexes must be written inline as literal '
    'Index([...]) entries (not a const variable, a spread or a non-literal), '
    'and the edited field must not already carry @Indexed.\n'
    '${_pasteAdvice(indexDeclarationSource(parts), modelName)}';

String _pasteAdvice(String declaration, String modelName) =>
    "Paste by hand into $modelName's @Collection(indexes: [...]): "
    '$declaration';

String _didYouMean(String name, List<String> names) {
  final ranked = [
    for (final candidate in names)
      (name: candidate, similarity: nameSimilarity(name, candidate)),
  ]..sort((a, b) => b.similarity.compareTo(a.similarity));
  final best = ranked.firstOrNull;
  if (best == null || best.similarity < 0.4) {
    return '';
  }
  return 'Did you mean "${best.name}"?';
}

bool _fieldsEqual(List<String> a, List<String> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

/// `dart format` on [path]; returns the formatter's stderr when it fails.
Future<String> _dartFormat(String path) async {
  final result = await Process.run(Platform.resolvedExecutable, [
    'format',
    path,
  ]);
  if (result.exitCode != 0) {
    return 'dart format failed:\n${result.stderr}';
  }
  return '';
}

String _relativeTo(String root, String path) {
  final rootPath = root == '.' ? Directory.current.path : root;
  return path.startsWith('$rootPath/')
      ? path.substring(rootPath.length + 1)
      : path;
}
