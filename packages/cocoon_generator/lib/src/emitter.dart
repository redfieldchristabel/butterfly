/// Emission of the generated Dart code for one library's Cocoon models.
///
/// Pure string building: input is the committed [SchemaLock] (field numbers
/// and types come only from the lock) plus the extracted models; output is
/// the body of a `<file>.cocoon.dart` part file. Dart formatting is applied
/// afterwards by source_gen.
library;

import 'package:cocoon/cocoon.dart';

import 'extract.dart';

/// The members every class inherits from Object; a generated handle with such
/// a name would collide, so those get a `$` prefix (`Txn$.$hashCode`).
const _objectMemberNames = {
  'hashCode',
  'toString',
  'runtimeType',
  'noSuchMethod',
};

/// Emits the body of a `<file>.cocoon.dart` part file.
///
/// [models] and [embedded] are the library's extractions; their lock specs
/// must exist in [lock] (the builder validates that with the schema diff
/// first). Throws [CocoonBuildError] for problems the model authors must fix,
/// e.g. two collections sharing the last path id, or indexing a field type
/// that has no column.
String emitPartBody({
  required List<ExtractedModel> models,
  required List<ExtractedEmbedded> embedded,
  required SchemaLock lock,
}) {
  final sortedModels = [...models]
    ..sort((a, b) => a.clazz.name.compareTo(b.clazz.name));
  final instanceOwners = <String, String>{};
  for (final model in sortedModels) {
    final instanceName = CollectionPattern.parse(model.path).collectionId;
    final previous = instanceOwners[instanceName];
    if (previous != null) {
      throw CocoonBuildError(
        'Models $previous and ${model.clazz.name} both map to the generated '
        'top-level name "$instanceName"; give the collections different leaf '
        'ids',
      );
    }
    instanceOwners[instanceName] = model.clazz.name;
  }

  final out = StringBuffer();
  for (final model in sortedModels) {
    final spec = lock.collections[model.clazz.name];
    if (spec == null) {
      throw StateError(
        'Model ${model.clazz.name} has no lock entry; the schema diff must '
        'run before emission',
      );
    }
    out.write(_emitModel(model, spec, lock.version));
  }
  for (final embeddedClass in embedded) {
    final spec = lock.embedded[embeddedClass.clazz.name];
    if (spec == null) {
      throw StateError(
        'Embedded class ${embeddedClass.clazz.name} has no lock entry; the '
        'schema diff must run before emission',
      );
    }
    out.write(_emitEmbedded(embeddedClass, spec, lock.version));
  }
  return out.toString();
}

// -- Shared field emission ---------------------------------------------------

/// One stored field prepared for emission: identity from the lock, defaults
/// from the constructor.
final class _FieldEmit {
  const _FieldEmit({
    required this.name,
    required this.number,
    required this.type,
    required this.defaultCode,
  });

  final String name;
  final int number;
  final _Type type;

  /// The constructor default value's source code, or `null`.
  final String? defaultCode;

  /// The member name on the generated `<Model>$` holder: the field name,
  /// `$`-prefixed when the name would collide with an Object member.
  String get handleName => _memberName(name);

  String get local => '\$$name';
}

/// Builds the `_FieldEmit` list for [clazz] against [fieldsOf] (a collection
/// or embedded spec), in ascending lock number order.
List<_FieldEmit> _fieldsOf(
  ExtractedClass clazz,
  Iterable<FieldSpec> specs,
  Map<String, String> defaults,
) {
  final fields = <_FieldEmit>[];
  for (final field in clazz.fields) {
    FieldSpec? fieldSpec;
    for (final spec in specs) {
      if (spec.name == field.name) {
        fieldSpec = spec;
        break;
      }
    }
    if (fieldSpec == null) {
      throw StateError(
        'Field ${field.name} of ${clazz.name} has no lock entry; the schema '
        'diff must run before emission',
      );
    }
    if (field.type != fieldSpec.type) {
      throw StateError(
        'Field ${field.name} of ${clazz.name} is ${field.type} in the model '
        'but ${fieldSpec.type} in the lock; the schema diff must run before '
        'emission',
      );
    }
    fields.add(
      _FieldEmit(
        name: field.name,
        number: fieldSpec.number,
        type: _parseType(field.type),
        defaultCode: defaults[field.name],
      ),
    );
  }
  fields.sort((a, b) => a.number.compareTo(b.number));
  return fields;
}

/// Writes every field of a value named [valueExpr] into the writer named
/// [writerName], in ascending field-number order. Null values are skipped.
void _encodeFields(
  StringBuffer out,
  String indent,
  List<_FieldEmit> fields,
  String valueExpr,
) {
  for (final field in fields) {
    if (!field.type.nullable) {
      _writeValue(
        out,
        indent,
        writerName,
        '${field.number}',
        field.type,
        '$valueExpr.${field.name}',
      );
      continue;
    }
    out
      ..writeln('${indent}final ${field.local} = $valueExpr.${field.name};')
      ..writeln('${indent}if (${field.local} != null) {');
    _writeValue(
      out,
      '$indent  ',
      writerName,
      '${field.number}',
      field.type,
      field.local,
    );
    out.writeln('$indent}');
  }
}

/// The name of the writer every encode body writes through.
const writerName = 'writer';

/// Writes one non-null value of [type] under [number] into [writerName].
///
/// [number] is a literal (`'3'`) or a variable (`'"\$i"'`) for list elements;
/// [readExpr] evaluates to a non-null value of the field's type.
void _writeValue(
  StringBuffer out,
  String indent,
  String writer,
  String number,
  _Type type,
  String readExpr,
) {
  switch (type.base) {
    case _TypeBase.intT:
      out.writeln('$indent$writer.writeSint64($number, $readExpr);');
    case _TypeBase.doubleT:
      out.writeln('$indent$writer.writeDouble($number, $readExpr);');
    case _TypeBase.boolT:
      out.writeln('$indent$writer.writeBool($number, $readExpr);');
    case _TypeBase.stringT:
      out.writeln('$indent$writer.writeString($number, $readExpr);');
    case _TypeBase.dateTimeT:
      out.writeln(
        '$indent$writer.writeSint64('
        '$number, $readExpr.toUtc().microsecondsSinceEpoch);',
      );
    case _TypeBase.bytesT:
      out.writeln('$indent$writer.writeBytes($number, $readExpr);');
    case _TypeBase.enumT:
      out.writeln('$indent$writer.writeString($number, $readExpr.name);');
    case _TypeBase.embeddedT:
      out.writeln(
        '$indent${type.name}\$.writeTo($writer, $number, $readExpr);',
      );
    case _TypeBase.listT:
      out.writeln('$indent$writer.writeMessage($number, (nested) {');
      out.writeln('$indent  var \$i = 1;');
      out.writeln('$indent  for (final \$element in $readExpr) {');
      _writeValue(
        out,
        '$indent    ',
        'nested',
        '\$i',
        type.element!,
        '\$element',
      );
      out
        ..writeln('$indent    \$i++;')
        ..writeln('$indent  }')
        ..writeln('$indent});');
  }
}

/// The decode locals for [fields]: one typed variable per field, initialized
/// with the constructor default when there is one, else the proto3 zero
/// value, else nothing (nullable fields without a default).
void _decodeLocals(StringBuffer out, String indent, List<_FieldEmit> fields) {
  for (final field in fields) {
    final initializer =
        field.defaultCode ?? (field.type.nullable ? null : field.type.zero);
    if (initializer == null) {
      out.writeln('$indent${field.type.dartType} ${field.local};');
    } else {
      out.writeln(
        '$indent${field.type.dartType} ${field.local} = $initializer;',
      );
    }
  }
}

/// The switch cases reading every known field of [fields] from [reader];
/// unknown numbers fall through to the caller's `default: skip`.
void _decodeCases(
  StringBuffer out,
  String indent,
  List<_FieldEmit> fields,
  String reader,
) {
  for (final field in fields) {
    out.writeln('${indent}case ${field.number}:');
    _decodeFieldCase(out, '$indent  ', field, reader);
  }
}

void _decodeFieldCase(
  StringBuffer out,
  String indent,
  _FieldEmit field,
  String reader,
) {
  final local = field.local;
  switch (field.type.base) {
    case _TypeBase.intT:
      out.writeln('$indent$local = $reader.readSint64();');
    case _TypeBase.doubleT:
      out.writeln('$indent$local = $reader.readDouble();');
    case _TypeBase.boolT:
      out.writeln('$indent$local = $reader.readBool();');
    case _TypeBase.stringT:
      out.writeln('$indent$local = $reader.readString();');
    case _TypeBase.dateTimeT:
      out
        ..writeln('$indent$local = DateTime.fromMicrosecondsSinceEpoch(')
        ..writeln('$indent    $reader.readSint64(),')
        ..writeln('$indent    isUtc: true,')
        ..writeln('$indent  );');
    case _TypeBase.bytesT:
      out.writeln('$indent$local = $reader.readBytes();');
    case _TypeBase.enumT:
      out
        ..writeln('$indent$local = ${field.type.name}.values.byName(')
        ..writeln('$indent    $reader.readString(),')
        ..writeln('$indent  );');
    case _TypeBase.embeddedT:
      out.writeln('$indent$local = ${field.type.name}\$.readFrom($reader);');
    case _TypeBase.listT:
      final listReader = '\$${field.name}Reader';
      final items = '\$${field.name}Items';
      final elementType = field.type.element!.dartType;
      out
        ..writeln('${indent}final $listReader = $reader.readMessage();')
        ..writeln('${indent}final $items = <$elementType>[];')
        ..writeln('${indent}while (!$listReader.isAtEnd) {')
        ..writeln('$indent  $listReader.readTag();')
        ..writeln(
          '$indent  $items.add(${_readElement(field.type.element!, listReader)});',
        )
        ..writeln('$indent}')
        ..writeln('$indent$local = $items;');
  }
}

/// The expression reading one list element of [type] from a nested message
/// reader, after its tag was consumed.
String _readElement(_Type type, String reader) {
  switch (type.base) {
    case _TypeBase.intT:
      return '$reader.readSint64()';
    case _TypeBase.doubleT:
      return '$reader.readDouble()';
    case _TypeBase.boolT:
      return '$reader.readBool()';
    case _TypeBase.stringT:
      return '$reader.readString()';
    case _TypeBase.dateTimeT:
      return 'DateTime.fromMicrosecondsSinceEpoch('
          '$reader.readSint64(), isUtc: true)';
    case _TypeBase.bytesT:
      return '$reader.readBytes()';
    case _TypeBase.enumT:
      return '${type.name}.values.byName($reader.readString())';
    case _TypeBase.embeddedT:
      return '${type.name}\$.readFrom($reader)';
    case _TypeBase.listT:
      throw StateError('Nested lists are not supported');
  }
}

/// The constructor arguments reading the decode locals: positional values in
/// parameter order, then named arguments.
String _ctorArgs(ExtractedClass clazz) {
  final args = <String>[];
  for (final name in clazz.callOrder) {
    final value = '\$$name';
    args.add(clazz.namedParams.contains(name) ? '$name: $value' : value);
  }
  return args.join(', ');
}

String _memberName(String name) =>
    _objectMemberNames.contains(name) ? '\$$name' : name;

// -- Model -------------------------------------------------------------------

String _emitModel(
  ExtractedModel model,
  CollectionSpec spec,
  int schemaVersion,
) {
  final className = '${model.clazz.name}Collection';
  final holderName = '${model.clazz.name}\$';
  final instanceName = CollectionPattern.parse(model.path).collectionId;
  final fields = _fieldsOf(model.clazz, spec.fields, model.clazz.defaults);

  // Only fields that appear in some index (or are path params) get columns;
  // every field lives in the blob either way.
  final columns = <_FieldEmit>[];
  for (final index in model.indexes) {
    for (final part in index.fields) {
      final name = part.startsWith('-') ? part.substring(1) : part;
      if (model.params.contains(name)) {
        continue;
      }
      final field = fields.where((f) => f.name == name).firstOrNull;
      if (field == null) {
        throw StateError(
          'Index part "$name" of ${model.clazz.name} is not a field or path '
          'param',
        );
      }
      if (!columns.any((f) => f.name == name)) {
        if (!field.type.isColumnable) {
          throw CocoonBuildError(
            'Field "$name" of ${model.clazz.name} cannot be indexed: '
            '${field.type.original} has no column. Only int, double, bool, '
            'String, DateTime, Uint8List and enums can be indexed',
          );
        }
        columns.add(field);
      }
    }
  }

  final out = StringBuffer();
  out
    ..writeln()
    ..writeln('// -- ${model.clazz.name} ${'-' * 58} //')
    ..writeln()
    ..writeln(
      '/// The `${model.path}` collection of [${model.clazz.name}], generated '
      'by cocoon_generator from `cocoon.lock.json` (schema version '
      '$schemaVersion).',
    )
    ..writeln('///')
    ..writeln('/// Register [$instanceName] when opening the database:')
    ..writeln('/// `Cocoon.open(file, collections: [$instanceName])`.')
    ..writeln('const $instanceName = $className._();')
    ..writeln()
    ..writeln(
      '/// The SQLite adapter and canonical wire codec for '
      '[${model.clazz.name}].',
    )
    ..writeln(
      'final class $className extends CollectionAdapter<${model.clazz.name}> {',
    )
    ..writeln('  const $className._();')
    ..writeln()
    ..writeln(
      "  static final _pattern = CollectionPattern.parse('${model.path}');",
    )
    ..writeln()
    ..writeln('  @override')
    ..writeln("  String get model => '${model.clazz.name}';")
    ..writeln()
    ..writeln('  @override')
    ..writeln('  CollectionPattern get pattern => _pattern;')
    ..writeln()
    ..writeln('  @override');
  if (columns.isEmpty) {
    out.writeln(
      '  List<FieldColumn<${model.clazz.name}, Object?>> get columns => const [];',
    );
  } else {
    out.writeln(
      '  List<FieldColumn<${model.clazz.name}, Object?>> get columns => [',
    );
    for (final column in columns) {
      out.writeln('    $holderName.${column.handleName},');
    }
    out.writeln('  ];');
  }
  out
    ..writeln()
    ..writeln('  @override');
  if (model.indexes.isEmpty) {
    out.writeln('  List<IndexDef> get indexes => const [];');
  } else {
    out.writeln('  List<IndexDef> get indexes => [');
    for (final index in model.indexes) {
      out.writeln(
        '    IndexDef.fromFields(${_listLiteral(index.fields)}'
        '${index.unique ? ', unique: true' : ''}),',
      );
    }
    out.writeln('  ];');
  }
  out
    ..writeln()
    ..writeln('  @override')
    ..writeln('  Uint8List encode(${model.clazz.name} value) {')
    ..writeln('    final writer = WireWriter();');
  _encodeFields(out, '    ', fields, 'value');
  out
    ..writeln('    return writer.toBytes();')
    ..writeln('  }')
    ..writeln()
    ..writeln('  @override')
    ..writeln('  ${model.clazz.name} decode(Uint8List bytes) {')
    ..writeln('    final reader = WireReader(bytes);');
  _decodeLocals(out, '    ', fields);
  out
    ..writeln('    while (!reader.isAtEnd) {')
    ..writeln('      final tag = reader.readTag();')
    ..writeln('      switch (tag.field) {');
  _decodeCases(out, '        ', fields, 'reader');
  out
    ..writeln('        default:')
    ..writeln('          reader.skip(tag.type);')
    ..writeln('      }')
    ..writeln('    }')
    ..writeln(
      '    return ${model.clazz.constructorPrefix}(${_ctorArgs(model.clazz)});',
    )
    ..writeln('  }')
    ..writeln('}');

  if (columns.isNotEmpty || model.params.isNotEmpty) {
    out
      ..writeln()
      ..writeln(
        '/// Typed query handles for the indexed fields and path params of '
        '[${model.clazz.name}].',
      )
      ..writeln('final class $holderName {')
      ..writeln('  const $holderName._();')
      ..writeln();
    for (final column in columns) {
      out
        ..writeln(
          '  /// The `${column.name}` field column (lock number '
          '${column.number}).',
        )
        ..writeln(
          '  static final ${column.handleName} = ${_columnCtor(model.clazz.name, column)};',
        )
        ..writeln();
    }
    for (final param in model.params) {
      out
        ..writeln('  /// The `$param` path param of `${model.path}`.')
        ..writeln(
          "  static final ${_memberName(param)} = ParamColumn("
          "$className._pattern, '$param');",
        )
        ..writeln();
    }
    out.writeln('}');
  }
  return out.toString();
}

String _columnCtor(String model, _FieldEmit field) {
  final type = field.type;
  final vType = type.dartType;
  final read = "read: (v) => v.${field.name}";
  final nullableArg = type.nullable ? ', nullable: true' : '';
  switch (type.base) {
    case _TypeBase.intT:
      return "FieldColumn.integer<$model, $vType>('${field.name}', $read$nullableArg)";
    case _TypeBase.doubleT:
      return "FieldColumn.real<$model, $vType>('${field.name}', $read$nullableArg)";
    case _TypeBase.boolT:
      return "FieldColumn.boolean<$model, $vType>('${field.name}', $read$nullableArg)";
    case _TypeBase.stringT:
      return "FieldColumn.text<$model, $vType>('${field.name}', $read$nullableArg)";
    case _TypeBase.dateTimeT:
      return "FieldColumn.dateTime<$model, $vType>('${field.name}', $read$nullableArg)";
    case _TypeBase.bytesT:
      return "FieldColumn.blob<$model, $vType>('${field.name}', $read$nullableArg)";
    case _TypeBase.enumT:
      return "FieldColumn.enumerated<$model, $vType>('${field.name}', $read, "
          "values: ${type.name}.values$nullableArg)";
    case _TypeBase.listT:
    case _TypeBase.embeddedT:
      throw StateError('${type.original} cannot be a column');
  }
}

// -- Embedded ----------------------------------------------------------------

String _emitEmbedded(
  ExtractedEmbedded extracted,
  EmbeddedSpec spec,
  int schemaVersion,
) {
  final model = extracted.clazz.name;
  final holderName = '$model\$';
  final fields = _fieldsOf(
    extracted.clazz,
    spec.fields,
    extracted.clazz.defaults,
  );

  final out = StringBuffer();
  out
    ..writeln()
    ..writeln('// -- $model (embedded) ${'-' * 45} //')
    ..writeln()
    ..writeln(
      '/// Wire codec for the embedded class [$model], generated by '
      'cocoon_generator from `cocoon.lock.json` (schema version '
      '$schemaVersion).',
    )
    ..writeln('final class $holderName {')
    ..writeln('  const $holderName._();')
    ..writeln()
    ..writeln(
      '  /// Encodes [value] as the nested message [field] of [writer].',
    )
    ..writeln(
      '  static void writeTo(WireWriter writer, int field, $model value) {',
    )
    ..writeln('    writer.writeMessage(field, (nested) {')
    ..writeln('      _writeFields(nested, value);')
    ..writeln('    });')
    ..writeln('  }')
    ..writeln()
    ..writeln('  /// The value used when an old document has no [$model].')
    ..writeln(
      '  static $model zero() => '
      "${extracted.clazz.constructorPrefix}(${_zeroArgs(extracted.clazz, fields)});",
    )
    ..writeln()
    ..writeln('  static void _writeFields(WireWriter writer, $model value) {');
  _encodeFields(out, '    ', fields, 'value');
  out
    ..writeln('  }')
    ..writeln()
    ..writeln('  /// Decodes a nested message: [reader] sits after the tag.')
    ..writeln('  static $model readFrom(WireReader reader) {')
    ..writeln('    final nested = reader.readMessage();');
  _decodeLocals(out, '    ', fields);
  out
    ..writeln('    while (!nested.isAtEnd) {')
    ..writeln('      final tag = nested.readTag();')
    ..writeln('      switch (tag.field) {');
  _decodeCases(out, '        ', fields, 'nested');
  out
    ..writeln('        default:')
    ..writeln('          nested.skip(tag.type);')
    ..writeln('      }')
    ..writeln('    }')
    ..writeln(
      "    return ${extracted.clazz.constructorPrefix}(${_ctorArgs(extracted.clazz)});",
    )
    ..writeln('  }')
    ..writeln('}');
  return out.toString();
}

String _zeroArgs(ExtractedClass clazz, List<_FieldEmit> fields) {
  final args = <String>[];
  for (final name in clazz.callOrder) {
    final field = fields.where((f) => f.name == name).first;
    // A nullable field with no default decodes to null; a field with a
    // constructor default decodes to that default. Only otherwise does the
    // proto3 zero value apply.
    final zero =
        field.defaultCode ?? (field.type.nullable ? 'null' : field.type.zero);
    args.add(clazz.namedParams.contains(name) ? '$name: $zero' : zero);
  }
  return args.join(', ');
}

// -- Types -------------------------------------------------------------------

enum _TypeBase {
  intT,
  doubleT,
  boolT,
  stringT,
  dateTimeT,
  bytesT,
  enumT,
  listT,
  embeddedT,
}

/// A canonical lock type parsed for emission.
final class _Type {
  const _Type._(
    this.base, {
    required this.original,
    this.nullable = false,
    this.element,
    this.name,
  });

  final _TypeBase base;

  /// The canonical lock text this was parsed from, e.g.
  /// `List<embedded:Address>?`.
  final String original;

  /// Whether the whole type is nullable.
  final bool nullable;

  /// The element type, for lists.
  final _Type? element;

  /// The class name, for enums and embedded classes.
  final String? name;

  /// The Dart type used in generated declarations.
  String get dartType {
    final inner = switch (base) {
      _TypeBase.intT => 'int',
      _TypeBase.doubleT => 'double',
      _TypeBase.boolT => 'bool',
      _TypeBase.stringT => 'String',
      _TypeBase.dateTimeT => 'DateTime',
      _TypeBase.bytesT => 'Uint8List',
      _TypeBase.enumT => name!,
      _TypeBase.embeddedT => name!,
      // List elements are never nullable (the extraction rejects them), so
      // the element type needs no stripping.
      _TypeBase.listT => 'List<${element!.dartType}>',
    };
    return nullable ? '$inner?' : inner;
  }

  /// Whether the type maps to a [FieldColumn] (everything but lists and
  /// embedded classes).
  bool get isColumnable =>
      base != _TypeBase.listT && base != _TypeBase.embeddedT;

  /// The proto3 zero value for a missing non-nullable field.
  String get zero => switch (base) {
    _TypeBase.intT => '0',
    _TypeBase.doubleT => '0.0',
    _TypeBase.boolT => 'false',
    _TypeBase.stringT => "''",
    _TypeBase.dateTimeT => 'DateTime.utc(1970)',
    _TypeBase.bytesT => 'Uint8List(0)',
    _TypeBase.enumT => '$name.values.first',
    _TypeBase.listT => '<${element!.dartType}>[]',
    _TypeBase.embeddedT => '$name\$.zero()',
  };
}

_Type _parseType(String canonical) {
  final nullable = canonical.endsWith('?');
  final base = nullable
      ? canonical.substring(0, canonical.length - 1)
      : canonical;
  _Type simple(_TypeBase base) =>
      _Type._(base, original: canonical, nullable: nullable);
  if (base == 'int') return simple(_TypeBase.intT);
  if (base == 'double') return simple(_TypeBase.doubleT);
  if (base == 'bool') return simple(_TypeBase.boolT);
  if (base == 'String') return simple(_TypeBase.stringT);
  if (base == 'DateTime') return simple(_TypeBase.dateTimeT);
  if (base == 'Uint8List') return simple(_TypeBase.bytesT);
  if (base.startsWith('enum:')) {
    return _Type._(
      _TypeBase.enumT,
      original: canonical,
      nullable: nullable,
      name: base.substring(5),
    );
  }
  if (base.startsWith('embedded:')) {
    return _Type._(
      _TypeBase.embeddedT,
      original: canonical,
      nullable: nullable,
      name: base.substring(9),
    );
  }
  if (base.startsWith('List<') && base.endsWith('>')) {
    final element = base.substring(5, base.length - 1);
    if (element.endsWith('?')) {
      throw StateError('Nullable list elements are not supported: $canonical');
    }
    return _Type._(
      _TypeBase.listT,
      original: canonical,
      nullable: nullable,
      element: _parseType(element),
    );
  }
  throw StateError('Unknown lock type "$canonical"');
}

// -- Small helpers -----------------------------------------------------------

String _listLiteral(List<String> values) =>
    "const [${values.map((v) => "'$v'").join(', ')}]";
