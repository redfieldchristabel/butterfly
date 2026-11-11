import 'dart:convert';

import 'schema.dart';

/// Parses the text [SchemaLock.parse] accepts: the YAML block style the
/// `cocoon_generator` migrate command writes to `cocoon.lock`, or the older
/// JSON shape (`cocoon.lock.json`, a leading `{`).
///
/// The YAML side is a small reader for exactly the shape migrate writes —
/// nested block maps and sequences over strings, ints and bools,
/// single- or double-quoted scalars, `#` comments and empty `{}`/`[]`
/// collections — so the runtime package needs no YAML dependency. Anything
/// else (flow collections, anchors, multi-line scalars) is a
/// [FormatException].
SchemaLock parseLockText(String source) {
  final trimmed = source.trimLeft();
  if (trimmed.startsWith('{')) {
    return SchemaLock.fromJson(jsonDecode(source) as Map<String, Object?>);
  }
  return _LockYamlReader(source).read();
}

/// One significant source line: comments and blank lines removed.
final class _SourceLine {
  const _SourceLine(this.number, this.indent, this.text);

  /// The 1-based source line, for error messages.
  final int number;

  /// The number of leading spaces.
  final int indent;

  /// The content after the indent.
  final String text;
}

List<_SourceLine> _scan(String source) {
  final lines = <_SourceLine>[];
  final raw = source.split('\n');
  for (var i = 0; i < raw.length; i++) {
    var text = raw[i];
    if (text.endsWith('\r')) {
      text = text.substring(0, text.length - 1);
    }
    var indent = 0;
    while (indent < text.length && text.codeUnitAt(indent) == 0x20) {
      indent++;
    }
    if (indent < text.length && text.codeUnitAt(indent) == 0x09) {
      throw FormatException('cocoon.lock line ${i + 1}: tab indentation');
    }
    final content = text.substring(indent);
    if (content.isEmpty || content.startsWith('#')) {
      continue;
    }
    lines.add(_SourceLine(i + 1, indent, content));
  }
  return lines;
}

final class _LockYamlReader {
  _LockYamlReader(String source) : _lines = _scan(source);

  final List<_SourceLine> _lines;
  var _pos = 0;

  SchemaLock read() {
    if (_lines.isEmpty) {
      throw const FormatException('cocoon.lock is empty');
    }
    final value = _value(_lines.first.indent, allowScalar: false);
    if (_pos != _lines.length) {
      throw FormatException(
        'cocoon.lock line ${_lines[_pos].number}: unexpected content',
      );
    }
    if (value is! Map<String, Object?>) {
      throw const FormatException('cocoon.lock must be a mapping');
    }
    return SchemaLock.fromJson(value);
  }

  /// Parses the block value starting at the current line, whose content sits
  /// at [indent]: a mapping, a sequence, or — for a `- scalar` item already
  /// reduced to its remainder line — a plain scalar when [allowScalar].
  Object? _value(int indent, {required bool allowScalar}) {
    final line = _lines[_pos];
    if (_isSequenceEntry(line.text)) {
      return _sequence(indent);
    }
    if (_keyEnd(line.text) >= 0) {
      return _mapping(indent);
    }
    if (allowScalar) {
      _pos++;
      return _inlineValue(line.text, line);
    }
    throw FormatException(
      'cocoon.lock line ${line.number}: expected "key:" or a "- " item',
    );
  }

  /// Parses a block mapping whose keys sit at [indent].
  Map<String, Object?> _mapping(int indent) {
    final map = <String, Object?>{};
    while (_pos < _lines.length) {
      final line = _lines[_pos];
      if (line.indent < indent) {
        return map;
      }
      if (line.indent > indent) {
        throw FormatException(
          'cocoon.lock line ${line.number}: unexpected indent',
        );
      }
      if (_isSequenceEntry(line.text)) {
        throw FormatException(
          'cocoon.lock line ${line.number}: expected "key:", found a list item',
        );
      }
      final colon = _keyEnd(line.text);
      if (colon < 0) {
        throw FormatException(
          'cocoon.lock line ${line.number}: expected "key:"',
        );
      }
      final keyValue = _scalar(line.text.substring(0, colon), line);
      if (keyValue is! String) {
        throw FormatException(
          'cocoon.lock line ${line.number}: keys must be strings',
        );
      }
      final rest = line.text.substring(colon + 1).trimLeft();
      _pos++;
      if (rest.isEmpty) {
        if (_pos >= _lines.length || _lines[_pos].indent <= indent) {
          throw FormatException(
            'cocoon.lock line ${line.number}: "$keyValue" has no value',
          );
        }
        map[keyValue] = _value(_lines[_pos].indent, allowScalar: false);
      } else if (rest == '{}') {
        map[keyValue] = <String, Object?>{};
      } else if (rest == '[]') {
        map[keyValue] = <Object?>[];
      } else {
        map[keyValue] = _inlineValue(rest, line);
      }
    }
    return map;
  }

  /// Parses a block sequence whose items sit at [indent].
  List<Object?> _sequence(int indent) {
    final list = <Object?>[];
    while (_pos < _lines.length) {
      final line = _lines[_pos];
      if (line.indent < indent) {
        return list;
      }
      if (line.indent > indent || !_isSequenceEntry(line.text)) {
        throw FormatException(
          'cocoon.lock line ${line.number}: expected a "- " item',
        );
      }
      final rest = line.text.substring(1).trimLeft();
      if (rest.isEmpty) {
        _pos++;
        if (_pos >= _lines.length || _lines[_pos].indent <= indent) {
          throw FormatException(
            'cocoon.lock line ${line.number}: the item has no value',
          );
        }
        list.add(_value(_lines[_pos].indent, allowScalar: false));
      } else {
        // `- <rest>`: re-read the remainder as a line of its own, indented
        // past the dash — where the writer puts continuation lines.
        final innerIndent = line.indent + (line.text.length - rest.length);
        _lines[_pos] = _SourceLine(line.number, innerIndent, rest);
        list.add(_value(innerIndent, allowScalar: true));
      }
    }
    return list;
  }

  /// An inline value after `key:` or a dash: a scalar (a trailing ` #...`
  /// comment is stripped), never a flow collection or a block sequence.
  Object? _inlineValue(String rest, _SourceLine line) {
    if (rest.startsWith('[') || rest.startsWith('{')) {
      throw FormatException(
        'cocoon.lock line ${line.number}: only empty {} and [] are supported',
      );
    }
    if (rest == '-' || rest.startsWith('- ')) {
      throw FormatException(
        'cocoon.lock line ${line.number}: lists must start on their own line',
      );
    }
    return _scalar(_stripComment(rest), line);
  }

  /// Resolves one scalar: quoted text, `true`/`false`, an int, else a string.
  Object? _scalar(String raw, _SourceLine line) {
    final text = raw.trim();
    if (text.startsWith('\'')) {
      return _singleQuoted(text, line);
    }
    if (text.startsWith('"')) {
      return _doubleQuoted(text, line);
    }
    if (text == 'true') {
      return true;
    }
    if (text == 'false') {
      return false;
    }
    if (_intPattern.hasMatch(text)) {
      return int.parse(text);
    }
    return text;
  }

  String _singleQuoted(String text, _SourceLine line) {
    final body = StringBuffer();
    var i = 1;
    while (i < text.length) {
      final ch = text[i];
      if (ch == '\'') {
        if (i + 1 < text.length && text[i + 1] == '\'') {
          body.write('\'');
          i += 2;
          continue;
        }
        if (i + 1 != text.length) {
          throw FormatException(
            'cocoon.lock line ${line.number}: unexpected content after the '
            'closing quote',
          );
        }
        return body.toString();
      }
      body.write(ch);
      i++;
    }
    throw FormatException(
      'cocoon.lock line ${line.number}: unterminated string',
    );
  }

  String _doubleQuoted(String text, _SourceLine line) {
    final body = StringBuffer();
    var i = 1;
    while (i < text.length) {
      final ch = text[i];
      if (ch == '"') {
        if (i + 1 != text.length) {
          throw FormatException(
            'cocoon.lock line ${line.number}: unexpected content after the '
            'closing quote',
          );
        }
        return body.toString();
      }
      if (ch == '\\') {
        if (i + 1 >= text.length) {
          throw FormatException(
            'cocoon.lock line ${line.number}: unterminated escape',
          );
        }
        final escaped = text[i + 1];
        body.write(switch (escaped) {
          '\\' => '\\',
          '"' => '"',
          'n' => '\n',
          't' => '\t',
          'r' => '\r',
          _ => throw FormatException(
            'cocoon.lock line ${line.number}: unsupported escape \\$escaped',
          ),
        });
        i += 2;
        continue;
      }
      body.write(ch);
      i++;
    }
    throw FormatException(
      'cocoon.lock line ${line.number}: unterminated string',
    );
  }

  /// The index of the colon ending the key on [text], or -1 when the line is
  /// no `key:` entry: quoted keys may contain colons, plain keys end at the
  /// first `:` followed by a space or the end of the line.
  int _keyEnd(String text) {
    final first = text.codeUnitAt(0);
    if (first == 0x27 || first == 0x22) {
      // 0x27 = ', 0x22 = ".
      final quote = text[0];
      var i = 1;
      while (i < text.length) {
        final ch = text[i];
        if (quote == '\'' && ch == '\'') {
          if (i + 1 < text.length && text[i + 1] == '\'') {
            i += 2;
            continue;
          }
          break;
        }
        if (quote == '"') {
          if (ch == '\\') {
            i += 2;
            continue;
          }
          if (ch == '"') {
            break;
          }
        }
        i++;
      }
      if (i >= text.length) {
        return -1;
      }
      var j = i + 1;
      while (j < text.length && text[j] == ' ') {
        j++;
      }
      return j < text.length && text[j] == ':' ? j : -1;
    }
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x3A && // ':'
          (i + 1 == text.length || text[i + 1] == ' ')) {
        return i;
      }
    }
    return -1;
  }

  bool _isSequenceEntry(String text) => text == '-' || text.startsWith('- ');

  String _stripComment(String text) {
    for (var i = 1; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x23 && text[i - 1] == ' ') {
        return text.substring(0, i).trimRight();
      }
    }
    return text;
  }
}

final RegExp _intPattern = RegExp(r'^[-+]?[0-9]+$');
