/// SQL naming rules shared by the schema builders and the adapter contract.
///
/// Every Cocoon-owned name is derived deterministically from a Dart name, so
/// generated adapters and hand-written adapters produce identical tables.
library;

/// Pattern a model field or path-param name must match to be indexable.
final RegExp validNamePattern = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*$');

/// Name of the internal metadata table.
const String metaTableName = '_cocoon_meta';

/// Name of the internal change log table, one row per touched document per
/// committed write.
const String changesTableName = '_cocoon_changes';

/// Converts a Dart identifier to `snake_case`.
///
/// `Txn` becomes `txn`, `AccountNote` becomes `account_note` and acronym runs
/// stay together (`HTTPServer` becomes `http_server`).
String snakeCase(String name) {
  final out = StringBuffer();
  for (var i = 0; i < name.length; i++) {
    final ch = name[i];
    final isUpper = ch.toUpperCase() == ch && ch.toLowerCase() != ch;
    if (isUpper && i > 0) {
      final prev = name[i - 1];
      final prevIsUpper =
          prev.toUpperCase() == prev && prev.toLowerCase() != prev;
      final nextIsLower =
          i + 1 < name.length && name[i + 1].toLowerCase() == name[i + 1];
      if (!prevIsUpper || nextIsLower) {
        out.write('_');
      }
    }
    out.write(ch.toLowerCase());
  }
  return out.toString();
}

/// The SQL table name for a collection model.
///
/// Throws an [ArgumentError] for names Cocoon reserves: anything starting
/// with `sqlite_` (SQLite's own namespace) or `_cocoon` (Cocoon's internal
/// tables), and anything that isn't lowercase letters, digits and underscores.
String tableNameFor(String model) {
  final table = snakeCase(model);
  if (table.startsWith('sqlite_')) {
    throw ArgumentError.value(
      model,
      'model',
      'Table name "$table" may not start with "sqlite_" (reserved by SQLite)',
    );
  }
  if (table.startsWith('_cocoon')) {
    throw ArgumentError.value(
      model,
      'model',
      'Table name "$table" may not start with "_cocoon" (reserved by Cocoon)',
    );
  }
  if (table.isEmpty || !RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(table)) {
    throw ArgumentError.value(
      model,
      'model',
      'Model name must map to a valid SQL table name, got "$table"',
    );
  }
  return table;
}

/// The SQL column name that mirrors a model field (`bookedOn` ->
/// `f_booked_on`).
String fieldColumnName(String fieldName) => 'f_${snakeCase(fieldName)}';

/// The SQL column name that mirrors a path param (`accountId` ->
/// `p_account_id`).
String paramColumnName(String paramName) => 'p_${snakeCase(paramName)}';

/// Whether [name] may be used as a model field or path param in an adapter.
bool isValidColumnName(String name) => validNamePattern.hasMatch(name);
