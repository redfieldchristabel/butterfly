/// Extraction of Cocoon declarations from analyzer elements.
///
/// Shared by the build_runner builder and the `cocoon migrate` CLI: both need
/// the same view of the annotated models — the [DeclaredCollection] and
/// [DeclaredEmbedded] views for the schema diff, and the richer
/// [ExtractedModel]/[ExtractedEmbedded] views for code emission.
///
/// Types map to the lock's canonical names: `int`, `double`, `bool`,
/// `String`, `DateTime`, `Uint8List`, `enum:<Name>`, `List<...>`,
/// `Map<String|int,...>`, `embedded:<Name>`, with a `?` suffix for nullable
/// (maps and lists themselves; their elements and values are never nullable).
library;

import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:cocoon/cocoon.dart';
import 'package:source_gen/source_gen.dart';

final _collectionChecker = TypeChecker.typeNamed(
  Collection,
  inPackage: 'cocoon',
);
final _embeddedChecker = TypeChecker.typeNamed(Embedded, inPackage: 'cocoon');
final _ignoreChecker = TypeChecker.typeNamed(Ignore, inPackage: 'cocoon');
final _mirroredChecker = TypeChecker.typeNamed(Mirrored, inPackage: 'cocoon');

/// A user source problem: the generator reports [message] as a build error.
class CocoonBuildError implements Exception {
  CocoonBuildError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The one-line failure the builder shows when a model and the lock disagree:
/// `Cocoon schema changed for `name`: run
/// "dart run cocoon_generator:migrate" (summary).`
String schemaChangedMessage(String name, String summary) =>
    'Cocoon schema changed for $name: run '
    '"dart run cocoon_generator:migrate" ($summary).';

/// A one-line summary of [diff], for the builder's failure message.
String describeCollectionDiff(CollectionDiff diff) {
  if (diff.isNew) {
    return 'new collection';
  }
  final parts = <String>[
    if (diff.pathChanged) 'path changed',
    if (diff.added.isNotEmpty)
      'added: ${diff.added.map((f) => f.name).join(', ')}',
    if (diff.removed.isNotEmpty)
      'removed: ${diff.removed.map((f) => f.name).join(', ')}',
    if (diff.typeChanged.isNotEmpty)
      'type changed: ${diff.typeChanged.map((c) => '${c.$1.name}: ${c.$1.type} -> ${c.$2.type}').join(', ')}',
    if (diff.indexesChanged) 'indexes changed',
    if (diff.mirroredChanged)
      'mirrored fields changed: '
          '${diff.declared.mirrored.join(', ')}',
  ];
  return parts.join('; ');
}

/// A one-line summary of an embedded class [diff].
String describeEmbeddedDiff(EmbeddedDiff diff) {
  if (diff.isNew) {
    return 'new embedded class';
  }
  final parts = <String>[
    if (diff.added.isNotEmpty)
      'added: ${diff.added.map((f) => f.name).join(', ')}',
    if (diff.removed.isNotEmpty)
      'removed: ${diff.removed.map((f) => f.name).join(', ')}',
    if (diff.typeChanged.isNotEmpty)
      'type changed: ${diff.typeChanged.map((c) => '${c.$1.name}: ${c.$1.type} -> ${c.$2.type}').join(', ')}',
  ];
  return parts.join('; ');
}

/// One stored field of an extracted class: a name and a canonical type.
final class ExtractedField {
  const ExtractedField(this.name, this.type, {this.mirrored = false});

  /// The field name, e.g. `bookedOn`.
  final String name;

  /// The canonical lock type, e.g. `int`, `String?`, `List<embedded:Address>`.
  final String type;

  /// Whether the field carries `@Mirrored()`: a column without an index.
  /// Only meaningful on `@Collection` model fields; the extraction rejects
  /// the annotation on `@Embedded` fields.
  final bool mirrored;

  @override
  String toString() => '$name: $type';
}

/// One `@Index` of an extracted model.
final class ExtractedIndex {
  const ExtractedIndex(this.fields, {required this.unique});

  /// Index part names, `-` prefix for descending, e.g.
  /// `['accountId', '-bookedOn']`.
  final List<String> fields;

  /// Whether the index is unique.
  final bool unique;
}

/// The shape shared by models and embedded classes: stored fields plus the
/// single generative constructor used to build them.
final class ExtractedClass {
  const ExtractedClass({
    required this.name,
    required this.fields,
    required this.positionalParams,
    required this.namedParams,
    required this.constructorPrefix,
    required this.defaults,
  });

  /// The class name.
  final String name;

  /// Stored fields in declaration order.
  final List<ExtractedField> fields;

  /// Positional constructor parameter names, in parameter order.
  final List<String> positionalParams;

  /// Named constructor parameter names.
  final List<String> namedParams;

  /// How generated code calls the constructor: `Txn` or `Txn.expense`.
  final String constructorPrefix;

  /// Field name to constructor default value source code, for fields whose
  /// parameter has a default (used when decoding old documents).
  final Map<String, String> defaults;

  /// The parameter names in call order: positional first, then named.
  Iterable<String> get callOrder => [...positionalParams, ...namedParams];
}

/// An extracted `@Collection` model.
final class ExtractedModel {
  const ExtractedModel({
    required this.clazz,
    required this.path,
    required this.params,
    required this.indexes,
  });

  /// The model class.
  final ExtractedClass clazz;

  /// The collection path pattern, e.g. `accounts/{accountId}/txns`.
  final String path;

  /// The path param names in path order, e.g. `['accountId']`.
  final List<String> params;

  /// The declared indexes, in declaration order.
  final List<ExtractedIndex> indexes;

  /// The lock-side view used for the schema diff.
  DeclaredCollection get declared => DeclaredCollection(
    model: clazz.name,
    path: path,
    fields: [
      for (final field in clazz.fields) DeclaredField(field.name, field.type),
    ],
    indexes: [for (final index in indexes) index.fields],
    mirrored: [
      for (final field in clazz.fields)
        if (field.mirrored) field.name,
    ],
  );
}

/// An extracted `@Embedded` class referenced by at least one model.
final class ExtractedEmbedded {
  const ExtractedEmbedded({required this.clazz});

  /// The embedded class.
  final ExtractedClass clazz;

  /// The lock-side view used for the schema diff.
  DeclaredEmbedded get declared => DeclaredEmbedded(clazz.name, [
    for (final field in clazz.fields) DeclaredField(field.name, field.type),
  ]);
}

/// Everything one library declares for Cocoon.
final class LibraryDeclarations {
  const LibraryDeclarations({required this.models, required this.embedded});

  /// The `@Collection` models, in declaration order.
  final List<ExtractedModel> models;

  /// The `@Embedded` classes the models reference, transitively, ordered by
  /// class name.
  final List<ExtractedEmbedded> embedded;

  /// The lock-side collection view, parallel to [models].
  List<DeclaredCollection> get collections => [
    for (final model in models) model.declared,
  ];

  /// The lock-side embedded view, parallel to [embedded].
  List<DeclaredEmbedded> get embeddedDeclarations => [
    for (final embedded in embedded) embedded.declared,
  ];
}

/// Mutable extraction state: the embedded classes found so far and the ones
/// currently being extracted (to catch embedding cycles).
final class _Extraction {
  final embedded = <String, ExtractedEmbedded>{};
  final extracting = <String>{};
}

/// Returns the Cocoon declarations of [library], or `null` when the library
/// has no `@Collection` models.
LibraryDeclarations? extractLibrary(LibraryReader library) {
  final extraction = _Extraction();
  final models = <ExtractedModel>[];

  for (final annotated in library.annotatedWith(_collectionChecker)) {
    final element = annotated.element;
    if (element is! ClassElement) {
      throw CocoonBuildError(
        '@Collection can only annotate classes, not ${element.kind.displayName} '
        '"${element.displayName}"',
      );
    }
    models.add(_extractModel(element, annotated.annotation, extraction));
  }
  if (models.isEmpty) {
    return null;
  }
  return LibraryDeclarations(
    models: List.unmodifiable(models),
    embedded: List.unmodifiable(
      extraction.embedded.values.toList()
        ..sort((a, b) => a.clazz.name.compareTo(b.clazz.name)),
    ),
  );
}

ExtractedModel _extractModel(
  ClassElement element,
  ConstantReader annotation,
  _Extraction extraction,
) {
  final name = element.name!;
  if (element.isAbstract) {
    throw CocoonBuildError(
      'Model $name is abstract; Cocoon constructs model values when decoding, '
      'so the class must be concrete',
    );
  }
  CollectionPattern pattern;
  try {
    pattern = CollectionPattern.parse(annotation.read('path').stringValue);
  } on FormatException catch (error) {
    throw CocoonBuildError(
      'Model $name has an invalid @Collection path: ${error.message}',
    );
  }

  final indexes = <ExtractedIndex>[];
  final indexList = annotation.read('indexes');
  if (!indexList.isNull) {
    for (final object in indexList.listValue) {
      final index = ConstantReader(object);
      indexes.add(
        ExtractedIndex([
          for (final part in index.read('fields').listValue)
            part.toStringValue()!,
        ], unique: index.read('unique').boolValue),
      );
    }
  }

  final clazz = _extractClass(element, extraction, allowMirrored: true);
  try {
    tableNameFor(name);
  } on ArgumentError catch (error) {
    throw CocoonBuildError('Model $name: ${_argumentMessage(error)}');
  }
  return ExtractedModel(
    clazz: clazz,
    path: pattern.pattern,
    params: pattern.params,
    indexes: List.unmodifiable(indexes),
  );
}

ExtractedClass _extractClass(
  ClassElement element,
  _Extraction extraction, {
  required bool allowMirrored,
}) {
  final name = element.name!;
  if (element.isAbstract) {
    throw CocoonBuildError(
      'Class $name is abstract; Cocoon constructs values when decoding, so '
      'the class must be concrete',
    );
  }
  if (element.typeParameters.isNotEmpty) {
    throw CocoonBuildError(
      'Class $name is generic; Cocoon models and @Embedded classes must be '
      'plain non-generic classes',
    );
  }
  final generative = element.constructors.where((c) => !c.isFactory).toList();
  if (generative.length != 1) {
    throw CocoonBuildError(
      'Class $name must have exactly one generative constructor for Cocoon, '
      'found ${generative.length}',
    );
  }
  final constructor = generative.single;
  final constructorName = constructor.name ?? '';
  // The analyzer reports an unnamed constructor's name as 'new'; generated
  // code invokes it as plain `Name`, without the `.new` the lint flags.
  final isUnnamed = constructorName.isEmpty || constructorName == 'new';
  final constructorPrefix = isUnnamed ? name : '$name.$constructorName';

  final positionalParams = <String>[];
  final namedParams = <String>[];
  final defaults = <String, String>{};
  for (final parameter in constructor.formalParameters) {
    if (parameter.name == null) {
      throw CocoonBuildError(
        'Class $name has a constructor parameter without a name',
      );
    }
    if (parameter.isSuperFormal) {
      throw CocoonBuildError(
        'Class $name: super parameter "${parameter.name}" is not supported; '
        'declare constructor parameters as this.<field>',
      );
    }
    if (parameter.isNamed) {
      namedParams.add(parameter.name!);
    } else {
      positionalParams.add(parameter.name!);
    }
    if (parameter.hasDefaultValue) {
      defaults[parameter.name!] = parameter.defaultValueCode!;
    }
  }

  final paramTypes = {
    for (final parameter in constructor.formalParameters)
      parameter.name!: parameter.type,
  };
  final fields = <ExtractedField>[];
  for (final field in element.fields) {
    // Only declared, final, instance fields are stored. Getters are not
    // fields; analyzer-internal synthetic fields carry no constructor param
    // and are rejected by the param check below.
    if (field.isStatic || !field.isFinal) {
      continue;
    }
    if (_ignoreChecker.hasAnnotationOf(field)) {
      continue;
    }
    final fieldName = field.name!;
    if (!validNamePattern.hasMatch(fieldName)) {
      throw CocoonBuildError(
        'Field "$fieldName" of $name: names must match '
        '${validNamePattern.pattern}',
      );
    }
    final parameterType = paramTypes[fieldName];
    if (parameterType == null) {
      throw CocoonBuildError(
        'Field "$fieldName" of $name has no constructor parameter; every '
        'stored field needs a matching generative-constructor parameter '
        '(this.$fieldName)',
      );
    }
    final fieldType = _canonicalType(
      field.type,
      context: 'field "$fieldName" of $name',
      extraction: extraction,
    );
    final parameterCanonical = _canonicalType(
      parameterType,
      context: 'parameter "$fieldName" of $name',
      extraction: extraction,
    );
    if (fieldType != parameterCanonical) {
      throw CocoonBuildError(
        'Field "$fieldName" of $name is $fieldType but its constructor '
        'parameter is $parameterCanonical; they must match',
      );
    }
    final mirrored = _mirroredChecker.hasAnnotationOf(field);
    fields.add(ExtractedField(fieldName, fieldType, mirrored: mirrored));
    if (mirrored && !allowMirrored) {
      throw CocoonBuildError(
        'Field "$fieldName" of $name cannot be @Mirrored: the annotation is '
        'only allowed on @Collection model fields. Embedded fields live '
        'inside the document blob and have no column, so there is nothing '
        'to mirror',
      );
    }
  }

  final fieldNames = {for (final field in fields) field.name};
  for (final parameter in constructor.formalParameters) {
    if (!fieldNames.contains(parameter.name)) {
      throw CocoonBuildError(
        'Constructor parameter "${parameter.name}" of $name has no matching '
        'stored field; constructor parameters and stored (final, non-@Ignore) '
        'fields must correspond one to one',
      );
    }
  }

  return ExtractedClass(
    name: name,
    fields: List.unmodifiable(fields),
    positionalParams: List.unmodifiable(positionalParams),
    namedParams: List.unmodifiable(namedParams),
    constructorPrefix: constructorPrefix,
    defaults: Map.unmodifiable(defaults),
  );
}

String _canonicalType(
  DartType type, {
  required String context,
  required _Extraction extraction,
}) {
  final base = _canonicalBase(type, context, extraction);
  return type.nullabilitySuffix == NullabilitySuffix.question ? '$base?' : base;
}

String _canonicalBase(DartType type, String context, _Extraction extraction) {
  if (type.isDartCoreInt) {
    return 'int';
  }
  if (type.isDartCoreDouble) {
    return 'double';
  }
  if (type.isDartCoreBool) {
    return 'bool';
  }
  if (type.isDartCoreString) {
    return 'String';
  }
  if (_isNamedCoreType(type, 'DateTime')) {
    return 'DateTime';
  }
  if (_isNamedCoreType(type, 'Uint8List', uri: 'dart:typed_data')) {
    return 'Uint8List';
  }
  if (type.isDartCoreList) {
    final arguments = (type as InterfaceType).typeArguments;
    final element = arguments.single;
    if (element.nullabilitySuffix == NullabilitySuffix.question) {
      throw CocoonBuildError(
        '$context: list elements may not be nullable '
        '(${element.getDisplayString()}); make the list itself nullable instead',
      );
    }
    if (element.isDartCoreList) {
      throw CocoonBuildError(
        '$context: nested lists (${element.getDisplayString()}) are not '
        'supported; flatten the list or move the inner list into an '
        '@Embedded class',
      );
    }
    return 'List<${_canonicalBase(element, context, extraction)}>';
  }
  if (type.isDartCoreMap) {
    final arguments = (type as InterfaceType).typeArguments;
    final key = arguments[0];
    final value = arguments[1];
    final keyCanonical = key.isDartCoreString
        ? 'String'
        : key.isDartCoreInt
        ? 'int'
        : null;
    if (keyCanonical == null) {
      throw CocoonBuildError(
        '$context: map keys must be String or int, not '
        '${key.getDisplayString()}',
      );
    }
    if (value.nullabilitySuffix == NullabilitySuffix.question) {
      throw CocoonBuildError(
        '$context: map values may not be nullable '
        '(${value.getDisplayString()}); encode absence by omitting the entry',
      );
    }
    final valueCanonical = _canonicalBase(value, context, extraction);
    if (valueCanonical.contains('Map<')) {
      throw CocoonBuildError(
        '$context: a Map value inside a Map is not supported '
        '(${value.getDisplayString()})',
      );
    }
    return 'Map<$keyCanonical,$valueCanonical>';
  }
  final element = type.element;
  if (element is EnumElement) {
    return 'enum:${element.name}';
  }
  if (element is ClassElement) {
    if (_collectionChecker.hasAnnotationOf(element)) {
      throw CocoonBuildError(
        '$context: ${element.name} is a @Collection model; nested values must '
        'use @Embedded classes',
      );
    }
    if (_embeddedChecker.hasAnnotationOf(element)) {
      final className = element.name!;
      if (extraction.extracting.contains(className)) {
        throw CocoonBuildError(
          '$context: embedded class $className embeds itself (directly or '
          'through another embedded class)',
        );
      }
      if (!extraction.embedded.containsKey(className)) {
        extraction.extracting.add(className);
        try {
          extraction.embedded[className] = ExtractedEmbedded(
            clazz: _extractClass(element, extraction, allowMirrored: false),
          );
        } finally {
          extraction.extracting.remove(className);
        }
      }
      return 'embedded:$className';
    }
    throw CocoonBuildError(
      '$context: unsupported type ${element.name}. Cocoon stores int, double, '
      'bool, String, DateTime, Uint8List, enums, List<...> and '
      'Map<String|int, ...> of those, and @Embedded classes',
    );
  }
  throw CocoonBuildError(
    '$context: unsupported type ${type.getDisplayString()}. Cocoon stores '
    'int, double, bool, String, DateTime, Uint8List, enums, List<...> and '
    'Map<String|int, ...> of those, and @Embedded classes',
  );
}

/// Whether [type] is the type named [name] from [uri] (default `dart:core`).
bool _isNamedCoreType(DartType type, String name, {String uri = 'dart:core'}) {
  final element = type.element;
  return element is InterfaceElement &&
      element.name == name &&
      element.library.uri.toString() == uri;
}

String _argumentMessage(ArgumentError error) {
  final message = error.message ?? '';
  final name = error.name;
  return name == null || name.isEmpty
      ? message.toString()
      : '$message (in $name)';
}
