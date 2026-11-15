/// Prefs & single models: the facade objects behind `db.prefs` and
/// `db.single`.
///
/// Some apps hold exactly one of something: the current signed-in user, the
/// chosen theme, the last opened tab, an onboarding flag, a feature toggle.
/// A document database makes you model that as a collection: declare a
/// model, register a collection, pick a hardcoded id ("1", "me") and carry
/// a one-row table for the rest of the app's life. Every read then looks
/// like `db.collection(users).doc('1').get()`, which reads like a bug and
/// invites a second row nobody wants. The only comfortable tool for this
/// today is Flutter's shared_preferences, which means a second storage
/// system: it is not in the Cocoon file, so it is not in Cocoon backups,
/// cannot join a Cocoon transaction ("set the current user and create their
/// first account, or neither"), and cannot be watched with the same
/// streams.
///
/// `db.prefs` is a key-value store for primitives; `db.single(adapter,
/// key:)` is one typed model under one key. Both live in the same database
/// file with no collection, no index and no change-log entries, and — after
/// one [CocoonPrefs.preload] — read synchronously at memory speed.
///
/// The preload map and the prefs watches live HERE, on the caller isolate,
/// in every isolate mode: storage ops route through the runtime (SQLite in
/// caller and auto mode, messages in background mode), and every committed
/// mutation is written through the map when its awaited call returns, in
/// commit order. A rolled-back transaction never touches the map.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'adapter.dart';
import 'cocoon.dart';
import 'naming.dart';
import 'prefs_store.dart';
import 'runtime.dart';
import 'transaction_guard.dart';

/// Decodes a raw pref row as [T]: the primitive kinds cast to their Dart
/// type; [T] dynamic or Object? accepting any primitive kind. A model row
/// (another adapter's single-model key) or an unsupported type parameter
/// throws a [PrefsTypeException] — never garbage.
@internal
T? decodePref<T extends Object?>(PrefRow? row, {required String key}) {
  if (row == null) {
    return null;
  }
  switch (row.kind) {
    case prefsKindString:
      return _fitPref<T>(decodePrefString(row.bytes), row, key);
    case prefsKindInt:
      return _fitPref<T>(decodePrefInt(row.bytes), row, key);
    case prefsKindBool:
      return _fitPref<T>(decodePrefBool(row.bytes), row, key);
    case prefsKindDouble:
      return _fitPref<T>(decodePrefDouble(row.bytes), row, key);
    case prefsKindBytes:
      return _fitPref<T>(decodePrefBytes(row.bytes), row, key);
    default:
      throw PrefsTypeException(
        key: key,
        storedKind: prefsKindName(row.kind),
        requestedKind: 'a primitive of type $T',
      );
  }
}

T _fitPref<T>(Object value, PrefRow row, String key) {
  final t = T;
  if (t == Object || t == dynamic) {
    return value as T;
  }
  final int? requested = switch (t) {
    String => prefsKindString,
    int => prefsKindInt,
    bool => prefsKindBool,
    double => prefsKindDouble,
    Uint8List => prefsKindBytes,
    _ => null,
  };
  if (requested == null) {
    throw PrefsTypeException(
      key: key,
      storedKind: prefsKindName(row.kind),
      requestedKind:
          '$T (prefs.watch supports the primitive kinds only; use '
          'Single.watch for a single-model key)',
    );
  }
  if (requested != row.kind) {
    throw PrefsTypeException(
      key: key,
      storedKind: prefsKindName(row.kind),
      requestedKind: prefsKindName(requested),
    );
  }
  return value as T;
}

/// A transaction's prefs view, accessed as `tx.prefs` inside a
/// [Cocoon.runTransaction] body.
///
/// Ops route through the transaction object — read-your-writes inside the
/// transaction, atomic with the collection writes in the same transaction
/// ("set the current user and create their first account, or neither") —
/// and reach the facade's preload map and watches only when the commit
/// succeeds, in commit order. A rollback leaves both untouched. The
/// facade's surface minus the extras: `get*`, `set*` and `remove` only.
final class TxPrefs {
  /// Builds the view; the engine's transaction plumbing does.
  @internal
  TxPrefs(this._tx, this._stage);

  final CocoonTxPrefs _tx;
  final PrefTxStage _stage;

  /// Reads a string pref inside the transaction; `null` when absent.
  Future<String?> getString(String key) async {
    checkPrefKey(key);
    final row = await _tx.get(key);
    if (row == null) {
      return null;
    }
    _checkKind(row, prefsKindString, key, 'string');
    return decodePrefString(row.bytes);
  }

  /// Reads an int pref inside the transaction; `null` when absent.
  Future<int?> getInt(String key) async {
    checkPrefKey(key);
    final row = await _tx.get(key);
    if (row == null) {
      return null;
    }
    _checkKind(row, prefsKindInt, key, 'int');
    return decodePrefInt(row.bytes);
  }

  /// Reads a bool pref inside the transaction; `null` when absent.
  Future<bool?> getBool(String key) async {
    checkPrefKey(key);
    final row = await _tx.get(key);
    if (row == null) {
      return null;
    }
    _checkKind(row, prefsKindBool, key, 'bool');
    return decodePrefBool(row.bytes);
  }

  /// Reads a double pref inside the transaction; `null` when absent.
  Future<double?> getDouble(String key) async {
    checkPrefKey(key);
    final row = await _tx.get(key);
    if (row == null) {
      return null;
    }
    _checkKind(row, prefsKindDouble, key, 'double');
    return decodePrefDouble(row.bytes);
  }

  /// Reads a bytes pref inside the transaction; `null` when absent.
  Future<Uint8List?> getBytes(String key) async {
    checkPrefKey(key);
    final row = await _tx.get(key);
    if (row == null) {
      return null;
    }
    _checkKind(row, prefsKindBytes, key, 'bytes');
    return decodePrefBytes(row.bytes);
  }

  /// Upserts a string pref inside the transaction.
  Future<void> setString(String key, String value) =>
      _set(key, prefsKindString, encodePrefString(value));

  /// Upserts an int pref inside the transaction.
  Future<void> setInt(String key, int value) =>
      _set(key, prefsKindInt, encodePrefInt(value));

  /// Upserts a bool pref inside the transaction.
  Future<void> setBool(String key, bool value) =>
      _set(key, prefsKindBool, encodePrefBool(value));

  /// Upserts a double pref inside the transaction.
  Future<void> setDouble(String key, double value) =>
      _set(key, prefsKindDouble, encodePrefDouble(value));

  /// Upserts a bytes pref inside the transaction.
  Future<void> setBytes(String key, Uint8List value) =>
      _set(key, prefsKindBytes, encodePrefBytes(value));

  /// Removes a pref inside the transaction. Removing an absent key changes
  /// nothing: no watch emission, no preload-map touch.
  Future<void> remove(String key) async {
    checkPrefKey(key);
    if (await _tx.remove(key)) {
      _stage.add((key: key, row: null));
    }
  }

  Future<void> _set(String key, int kind, Uint8List bytes) async {
    checkPrefKey(key);
    final row = (kind: kind, bytes: bytes);
    await _tx.put(key, row);
    _stage.add((key: key, row: row));
  }

  void _checkKind(PrefRow row, int requested, String key, String name) {
    if (row.kind != requested) {
      throw PrefsTypeException(
        key: key,
        storedKind: prefsKindName(row.kind),
        requestedKind: name,
      );
    }
  }
}

/// A transaction's typed single-model view, accessed as
/// `tx.single(adapter, key:)` inside a [Cocoon.runTransaction] body — the
/// transaction's counterpart of [Single]. Atomic with the collection
/// writes in the same transaction.
final class TxSingle<T extends Object> {
  /// Builds the view; the engine's transaction plumbing does.
  @internal
  TxSingle(this._tx, this._adapter, this._key, this._stage) {
    _expectedKind = prefsModelKind(tableNameFor(_adapter.model));
  }

  final CocoonTxPrefs _tx;
  final CollectionAdapter<T> _adapter;
  final String _key;
  final PrefTxStage _stage;
  late final int _expectedKind;

  /// Reads the model inside the transaction; `null` when absent.
  Future<T?> get() async {
    checkPrefKey(_key);
    final row = await _tx.get(_key);
    if (row == null) {
      return null;
    }
    _checkAdapter(row);
    return _adapter.decode(row.bytes);
  }

  /// Upserts the model inside the transaction.
  Future<void> set(T value) async {
    checkPrefKey(_key);
    final row = (kind: _expectedKind, bytes: _adapter.encode(value));
    await _tx.put(_key, row);
    _stage.add((key: _key, row: row));
  }

  /// Removes the model inside the transaction. Removing an absent key
  /// changes nothing: no watch emission, no preload-map touch.
  Future<void> clear() async {
    checkPrefKey(_key);
    if (await _tx.remove(_key)) {
      _stage.add((key: _key, row: null));
    }
  }

  void _checkAdapter(PrefRow row) {
    if (row.kind != _expectedKind) {
      throw PrefsTypeException(
        key: _key,
        storedKind: prefsKindName(row.kind),
        requestedKind: 'a single model ${_adapter.model}',
      );
    }
  }
}

/// The staged pref mutations of one [Cocoon.runTransaction] body. Created
/// by the facade per transaction; written through the preload map and the
/// watches once the commit succeeds, in commit order — a rollback discards
/// it, so neither the map nor the watches reflect any of it.
@internal
final class PrefTxStage {
  /// The body's pref mutations, in the order the body made them.
  final List<PrefWriteOp> ops = [];

  /// Adds a mutation.
  void add(PrefWriteOp op) => ops.add(op);
}

/// A prefs watch stream's machinery: emits the current value on the first
/// listen, then every committed mutation of its key in commit order.
///
/// Mutations arriving while the point-in-time initial read is in flight are
/// buffered and delivered in order, so the sequence is
/// [value at listen] [every later committed value].
final class _PrefWatch<T> {
  _PrefWatch(
    this._key,
    this._decode,
    this._readCurrent,
    this._onListen,
    this._onCancel,
  );

  final String _key;
  final T? Function(PrefRow?) _decode;
  final Future<PrefRow?> Function() _readCurrent;
  final void Function(_PrefWatch<T>) _onListen;
  final void Function(_PrefWatch<T>) _onCancel;

  late final StreamController<T?> controller = StreamController<T?>.broadcast(
    onListen: () {
      _onListen(this);
      _startInitial();
    },
    onCancel: () => _onCancel(this),
  );

  /// The user-facing stream; work starts on the first listen and stops on
  /// the last cancel.
  Stream<T?> get stream => controller.stream;

  int _pendingInitials = 0;
  final List<void Function()> _buffer = [];

  void _startInitial() {
    _pendingInitials++;
    unawaited(_emitInitial());
  }

  Future<void> _emitInitial() async {
    PrefRow? row;
    try {
      row = await _readCurrent();
    } on Object catch (error, stackTrace) {
      if (!controller.isClosed) {
        controller.addError(error, stackTrace);
      }
    }
    if (controller.isClosed) {
      return;
    }
    _addToController(row);
    _pendingInitials--;
    if (_pendingInitials == 0) {
      for (final deliver in _buffer) {
        if (controller.isClosed) {
          return;
        }
        deliver();
      }
      _buffer.clear();
    }
  }

  /// Delivers one committed mutation, in commit order; buffered while an
  /// initial read is in flight.
  void deliver(PrefRow? row) {
    if (_pendingInitials > 0) {
      _buffer.add(() => _addToController(row));
      return;
    }
    _addToController(row);
  }

  void _addToController(PrefRow? row) {
    if (controller.isClosed) {
      return;
    }
    try {
      controller.add(_decode(row));
    } on Object catch (error, stackTrace) {
      // A wrong-kind read (the caller's type parameter does not fit the
      // stored row, or the row is another adapter's single-model row) is a
      // programming error: delivered as an error event; the stream stays
      // open for the next write to fix the kind.
      controller.addError(error, stackTrace);
    }
  }

  void close() {
    if (!controller.isClosed) {
      controller.close();
    }
  }
}

/// One typed model under one key, for "the current signed-in user" style
/// data — the one-of-a-kind counterpart of a collection.
///
/// Some apps hold exactly one of something: the current signed-in user, the
/// chosen theme, the last opened tab. A document database makes you model
/// that as a collection: declare a model, register a collection, pick a
/// hardcoded id ("1", "me") and carry a one-row table for the rest of the
/// app's life. Every read then looks like
/// `db.collection(users).doc('1').get()`, which reads like a bug and
/// invites a second row nobody wants. [Single] is the comfortable tool,
/// inside the Cocoon file: no collection to register, no table, no index —
/// the model is a normal generated Cocoon model, stored under one key in
/// the same file as everything else, atomic with collection writes in the
/// same transaction, watched with the same stream shape and read
/// synchronously after one preload.
///
/// ```dart
/// final currentUser = db.single(userAdapter, key: 'currentUser');
/// await currentUser.set(user);
/// final u = await currentUser.get(); // User?
/// ```
///
/// The model class is a normal generated Cocoon model: the adapter's
/// `encode`/`decode` codecs are reused as-is, and the stored bytes are
/// exactly the bytes the adapter returns, so model evolution behaves
/// exactly like a collection document. `@Index`/`@Mirrored` fields on a
/// single model are ignored (nothing to index — there is only the one
/// value). Two handles with the same key but different adapters detect the
/// mismatch through the row's kind hash (a [PrefsTypeException]); the key
/// is otherwise typed by convention. Not encrypted: the file is plain
/// SQLite, so tokens, passwords and keys do NOT belong here — keep secrets
/// in the platform keystore for now.
final class Single<T extends Object> {
  /// Builds the handle; applications get one from `db.single(adapter,
  /// key:)`.
  @internal
  Single(this._store, this._adapter, this._key);

  final CocoonPrefs _store;
  final CollectionAdapter<T> _adapter;
  final String _key;

  /// Upserts the model.
  ///
  /// Inside a [Cocoon.runTransaction] body use `tx.single(adapter, key:)`
  /// — calling this on the database throws a [TransactionMisuseError]: the
  /// write would wait forever for the transaction's own write lock.
  Future<void> set(T value) =>
      _store.putSingle(_adapter, _key, value, 'Single.set');

  /// Reads the model; `null` when absent.
  ///
  /// Inside a [Cocoon.runTransaction] body use `tx.single(adapter, key:)`
  /// — calling this on the database throws a [TransactionMisuseError]: the
  /// read can never see the transaction's own uncommitted writes.
  Future<T?> get() => _store.getSingle(_adapter, _key, 'Single.get');

  /// Removes the model. Removing an absent key changes nothing.
  ///
  /// Inside a [Cocoon.runTransaction] body use `tx.single(adapter, key:)`
  /// — calling this on the database throws a [TransactionMisuseError]: the
  /// write would wait forever for the transaction's own write lock.
  Future<void> clear() => _store.clearSingle(_adapter, _key, 'Single.clear');

  /// Watches the key: emits the current model first (the value at listen),
  /// then every committed mutation in commit order. Closing the database
  /// completes the stream.
  Stream<T?> watch() => _store.watchSingle(_adapter, _key);

  /// Reads the model synchronously, after preload: decodes lazily and
  /// caches the decoded model. `null` when absent.
  ///
  /// Throws a [StateError] before [CocoonPrefs.preload] ran and after the
  /// database closed. Throws a [PrefsTypeException] when the row was
  /// written by another adapter.
  T? getSync() => _store.getSingleSync(_adapter, _key);
}

/// The key-value store behind `db.prefs`: primitives in the same database
/// file, no collection, no index, no change-log entries.
///
/// Some apps hold exactly one of something — the chosen theme, the last
/// opened tab, an onboarding flag, a feature toggle. A document database
/// makes you model that as a collection: declare a model, register a
/// collection, pick a hardcoded id ("1", "me") and carry a one-row table
/// for the rest of the app's life. Every read then looks like
/// `db.collection(users).doc('1').get()`, which reads like a bug and
/// invites a second row nobody wants. The only comfortable tool for this
/// today is Flutter's shared_preferences, which means a second storage
/// system: it is not in the Cocoon file, so it is not in Cocoon backups,
/// cannot join a Cocoon transaction ("set the current user and create
/// their first account, or neither"), and cannot be watched with the same
/// streams. [CocoonPrefs] is that comfortable tool, inside the Cocoon
/// file: after one [preload] its reads are synchronous at memory speed,
/// its writes are atomic with collection writes in the same transaction,
/// and it travels with Cocoon backups.
///
/// Value kinds: [setString]/[getString], [setInt]/[getInt],
/// [setBool]/[getBool], [setDouble]/[getDouble] and [setBytes]/[getBytes].
/// Absent keys read `null`; reading a key as the wrong kind throws a
/// [PrefsTypeException] naming the key, the stored kind and the requested
/// kind — never garbage. Keys are non-empty and at most 256 UTF-8 bytes;
/// values have no size limit beyond SQLite, but prefs are documented for
/// small values (hundreds of keys, kilobytes).
///
/// Device-local by design: writes never enter the on-disk change log, so
/// [Cocoon.changesSince] never reports them and opt-in syncing is out of
/// scope. Not encrypted: the file is plain SQLite, so tokens, passwords
/// and keys do NOT belong here — keep secrets in the platform keystore
/// (e.g. flutter_secure_storage) for now.
final class CocoonPrefs {
  /// Builds the store; applications get one from `db.prefs`.
  @internal
  CocoonPrefs(this._db);

  final Cocoon _db;

  /// The preload map: every pref's raw row, authoritative for the sync
  /// getters and the watch machinery once [preload] ran. Write-through
  /// keeps it fresh after every committed mutation, in commit order.
  final Map<String, PrefRow> _rows = {};

  /// Whether [preload] has run; the sync getters throw a [StateError]
  /// before it.
  bool _preloaded = false;

  /// Set when the database closes: sync getters and watch starts throw the
  /// closed-database error from then on, and watch streams complete.
  bool _closed = false;

  /// One decoded-model memo per single key ([Single.getSync] decodes
  /// lazily and caches; a byte-identity check against the preload map
  /// guards correctness across overwrites).
  final Map<String, ({Uint8List bytes, Object value})> _models = {};

  /// Prefs watches by key.
  final Map<String, List<_PrefWatch<dynamic>>> _watches = {};

  // -- Async surface -----------------------------------------------------------

  /// Upserts a string pref.
  ///
  /// Inside a [Cocoon.runTransaction] body use `tx.prefs.setString` —
  /// calling this on the database throws a [TransactionMisuseError]: the
  /// write would wait forever for the transaction's own write lock.
  Future<void> setString(String key, String value) =>
      _put(key, prefsKindString, encodePrefString(value), 'Prefs.setString');

  /// Upserts an int pref.
  ///
  /// Inside a [Cocoon.runTransaction] body use `tx.prefs.setInt` — calling
  /// this on the database throws a [TransactionMisuseError]: the write
  /// would wait forever for the transaction's own write lock.
  Future<void> setInt(String key, int value) =>
      _put(key, prefsKindInt, encodePrefInt(value), 'Prefs.setInt');

  /// Upserts a bool pref.
  ///
  /// Inside a [Cocoon.runTransaction] body use `tx.prefs.setBool` —
  /// calling this on the database throws a [TransactionMisuseError]: the
  /// write would wait forever for the transaction's own write lock.
  Future<void> setBool(String key, bool value) =>
      _put(key, prefsKindBool, encodePrefBool(value), 'Prefs.setBool');

  /// Upserts a double pref.
  ///
  /// Inside a [Cocoon.runTransaction] body use `tx.prefs.setDouble` —
  /// calling this on the database throws a [TransactionMisuseError]: the
  /// write would wait forever for the transaction's own write lock.
  Future<void> setDouble(String key, double value) =>
      _put(key, prefsKindDouble, encodePrefDouble(value), 'Prefs.setDouble');

  /// Upserts a bytes pref.
  ///
  /// Inside a [Cocoon.runTransaction] body use `tx.prefs.setBytes` —
  /// calling this on the database throws a [TransactionMisuseError]: the
  /// write would wait forever for the transaction's own write lock.
  Future<void> setBytes(String key, Uint8List value) =>
      _put(key, prefsKindBytes, encodePrefBytes(value), 'Prefs.setBytes');

  /// Removes a pref. Removing an absent key changes nothing: no watch
  /// emission, no preload-map touch.
  ///
  /// Inside a [Cocoon.runTransaction] body use `tx.prefs.remove` — calling
  /// this on the database throws a [TransactionMisuseError]: the write
  /// would wait forever for the transaction's own write lock.
  Future<void> remove(String key) async {
    checkNotInTransaction(_db, 'Prefs.remove', read: false);
    _checkOpen();
    checkPrefKey(key);
    if (await _db.runtime.prefsRemove(key)) {
      applyCommitted([(key: key, row: null)]);
    }
  }

  /// Reads a string pref; `null` when absent.
  ///
  /// Inside a [Cocoon.runTransaction] body use `tx.prefs.getString` —
  /// calling this on the database throws a [TransactionMisuseError]: the
  /// read can never see the transaction's own uncommitted writes.
  Future<String?> getString(String key) async {
    final row = await _getRow(key, 'Prefs.getString', prefsKindString);
    return row == null ? null : decodePrefString(row.bytes);
  }

  /// Reads an int pref; `null` when absent.
  ///
  /// Inside a [Cocoon.runTransaction] body use `tx.prefs.getInt` — calling
  /// this on the database throws a [TransactionMisuseError]: the read can
  /// never see the transaction's own uncommitted writes.
  Future<int?> getInt(String key) async {
    final row = await _getRow(key, 'Prefs.getInt', prefsKindInt);
    return row == null ? null : decodePrefInt(row.bytes);
  }

  /// Reads a bool pref; `null` when absent.
  ///
  /// Inside a [Cocoon.runTransaction] body use `tx.prefs.getBool` —
  /// calling this on the database throws a [TransactionMisuseError]: the
  /// read can never see the transaction's own uncommitted writes.
  Future<bool?> getBool(String key) async {
    final row = await _getRow(key, 'Prefs.getBool', prefsKindBool);
    return row == null ? null : decodePrefBool(row.bytes);
  }

  /// Reads a double pref; `null` when absent.
  ///
  /// Inside a [Cocoon.runTransaction] body use `tx.prefs.getDouble` —
  /// calling this on the database throws a [TransactionMisuseError]: the
  /// read can never see the transaction's own uncommitted writes.
  Future<double?> getDouble(String key) async {
    final row = await _getRow(key, 'Prefs.getDouble', prefsKindDouble);
    return row == null ? null : decodePrefDouble(row.bytes);
  }

  /// Reads a bytes pref; `null` when absent.
  ///
  /// Inside a [Cocoon.runTransaction] body use `tx.prefs.getBytes` —
  /// calling this on the database throws a [TransactionMisuseError]: the
  /// read can never see the transaction's own uncommitted writes.
  Future<Uint8List?> getBytes(String key) async {
    final row = await _getRow(key, 'Prefs.getBytes', prefsKindBytes);
    return row == null ? null : decodePrefBytes(row.bytes);
  }

  /// Whether [key] has a pref.
  ///
  /// Inside a [Cocoon.runTransaction] body use `tx.prefs.get*` — calling
  /// this on the database throws a [TransactionMisuseError]: the read can
  /// never see the transaction's own uncommitted writes.
  Future<bool> containsKey(String key) async {
    checkNotInTransaction(_db, 'Prefs.containsKey', read: true);
    _checkOpen();
    checkPrefKey(key);
    if (_preloaded) {
      return _rows.containsKey(key);
    }
    return await _db.runtime.prefsGet(key) != null;
  }

  /// Every pref key, sorted.
  ///
  /// Inside a [Cocoon.runTransaction] body use `tx.prefs.get*` — calling
  /// this on the database throws a [TransactionMisuseError]: the read can
  /// never see the transaction's own uncommitted writes.
  Future<List<String>> keys() async {
    checkNotInTransaction(_db, 'Prefs.keys', read: true);
    _checkOpen();
    if (_preloaded) {
      return _rows.keys.toList()..sort();
    }
    return _db.runtime.prefsKeys();
  }

  /// Removes every pref. Collections are untouched.
  ///
  /// Inside a [Cocoon.runTransaction] body use `tx.prefs.remove` per key —
  /// calling this on the database throws a [TransactionMisuseError]: the
  /// write would wait forever for the transaction's own write lock.
  Future<void> clear() async {
    checkNotInTransaction(_db, 'Prefs.clear', read: false);
    _checkOpen();
    final keys = await _db.runtime.prefsClear();
    applyCommitted([for (final key in keys..sort()) (key: key, row: null)]);
  }

  /// Loads every pref into a small in-memory map and returns the key count.
  ///
  /// The sync getters ([getStringSync] and friends) throw a [StateError]
  /// before this ran. Idempotent and cheap to call twice; writes made
  /// before this are not lost (they are read from SQLite here). Every
  /// committed mutation after this is written through the map when its
  /// awaited call returns, in commit order — the watch streams and the
  /// sync getters can never disagree. A rolled-back transaction never
  /// touches the map.
  ///
  /// Apps that need synchronous reads from the first frame pass
  /// `preloadPrefs: true` to [Cocoon.open] instead. Inside a
  /// [Cocoon.runTransaction] body this throws a [TransactionMisuseError]
  /// (a read: it can never see the transaction's own uncommitted writes).
  ///
  /// Memory: the map holds the whole table, so prefs stay small
  /// (hundreds of keys, kilobytes). No eviction, no limits.
  Future<int> preload() async {
    checkNotInTransaction(_db, 'Prefs.preload', read: true);
    _checkOpen();
    if (_preloaded) {
      return _rows.length;
    }
    final rows = await _db.runtime.prefsLoadAll();
    _rows
      ..clear()
      ..addAll(rows);
    _preloaded = true;
    return _rows.length;
  }

  /// Watches [key]: emits the current value first (the value at listen),
  /// then every committed mutation of the key in commit order — set emits
  /// the new value, remove and a covering [clear] emit `null`, other keys
  /// never emit.
  ///
  /// The type parameter must fit the stored row: a wrong-kind read is
  /// delivered as a [PrefsTypeException] error event, and the row of
  /// another adapter's single-model key cannot be decoded here at all —
  /// use [Single.watch] for those. Starting a watch inside a
  /// [Cocoon.runTransaction] body is allowed (its first value reflects
  /// committed data; the transaction's mutations arrive with its commit).
  ///
  /// Closing the database completes the stream.
  Stream<T?> watch<T extends Object?>(String key) {
    _checkOpen();
    checkPrefKey(key);
    return _machine<T>(key, (row) => decodePref<T>(row, key: key)).stream;
  }

  // -- Sync surface (after preload) ---------------------------------------------

  /// Reads a string pref synchronously; `null` when absent.
  ///
  /// Throws a [StateError] before [preload] ran and after the database
  /// closed. Memory-speed after warm-up.
  String? getStringSync(String key) {
    final row = _getRowSync(key, prefsKindString, 'string');
    return row == null ? null : decodePrefString(row.bytes);
  }

  /// Reads an int pref synchronously; `null` when absent.
  ///
  /// Throws a [StateError] before [preload] ran and after the database
  /// closed. Memory-speed after warm-up.
  int? getIntSync(String key) {
    final row = _getRowSync(key, prefsKindInt, 'int');
    return row == null ? null : decodePrefInt(row.bytes);
  }

  /// Reads a bool pref synchronously; `null` when absent.
  ///
  /// Throws a [StateError] before [preload] ran and after the database
  /// closed. Memory-speed after warm-up.
  bool? getBoolSync(String key) {
    final row = _getRowSync(key, prefsKindBool, 'bool');
    return row == null ? null : decodePrefBool(row.bytes);
  }

  /// Reads a double pref synchronously; `null` when absent.
  ///
  /// Throws a [StateError] before [preload] ran and after the database
  /// closed. Memory-speed after warm-up.
  double? getDoubleSync(String key) {
    final row = _getRowSync(key, prefsKindDouble, 'double');
    return row == null ? null : decodePrefDouble(row.bytes);
  }

  /// Reads a bytes pref synchronously; `null` when absent.
  ///
  /// Throws a [StateError] before [preload] ran and after the database
  /// closed. Memory-speed after warm-up.
  Uint8List? getBytesSync(String key) {
    final row = _getRowSync(key, prefsKindBytes, 'bytes');
    return row == null ? null : decodePrefBytes(row.bytes);
  }

  /// Whether [key] has a pref, synchronously.
  ///
  /// Throws a [StateError] before [preload] ran and after the database
  /// closed.
  bool containsKeySync(String key) {
    _checkOpen();
    _checkPreloaded();
    checkPrefKey(key);
    return _rows.containsKey(key);
  }

  /// Every pref key, sorted, synchronously.
  ///
  /// Throws a [StateError] before [preload] ran and after the database
  /// closed.
  List<String> keysSync() {
    _checkOpen();
    _checkPreloaded();
    return _rows.keys.toList()..sort();
  }

  // -- Single models --------------------------------------------------------------

  /// Watches a single-model key: emits the current model first, then every
  /// committed mutation in commit order. Closing the database completes
  /// the stream.
  Stream<T?> watchSingle<T extends Object>(
    CollectionAdapter<T> adapter,
    String key,
  ) {
    _checkOpen();
    checkPrefKey(key);
    final expected = prefsModelKind(tableNameFor(adapter.model));
    return _machine<T?>(key, (row) {
      if (row == null) {
        return null;
      }
      if (row.kind != expected) {
        throw PrefsTypeException(
          key: key,
          storedKind: prefsKindName(row.kind),
          requestedKind: 'a single model ${adapter.model}',
        );
      }
      return adapter.decode(row.bytes);
    }).stream;
  }

  /// Reads a single-model key synchronously, after preload: decodes lazily
  /// and caches the decoded model. `null` when absent.
  T? getSingleSync<T extends Object>(CollectionAdapter<T> adapter, String key) {
    _checkOpen();
    _checkPreloaded();
    checkPrefKey(key);
    final expected = prefsModelKind(tableNameFor(adapter.model));
    final row = _rows[key];
    if (row == null) {
      return null;
    }
    if (row.kind != expected) {
      throw PrefsTypeException(
        key: key,
        storedKind: prefsKindName(row.kind),
        requestedKind: 'a single model ${adapter.model}',
      );
    }
    final memo = _models[key];
    if (memo != null && identical(memo.bytes, row.bytes)) {
      return memo.value as T;
    }
    final value = adapter.decode(row.bytes);
    _models[key] = (bytes: row.bytes, value: value);
    return value;
  }

  // -- Facade internals -------------------------------------------------------------

  Future<void> _put(String key, int kind, Uint8List bytes, String op) async {
    checkNotInTransaction(_db, op, read: false);
    _checkOpen();
    checkPrefKey(key);
    final row = (kind: kind, bytes: bytes);
    await _db.runtime.prefsPut(key, row);
    applyCommitted([(key: key, row: row)]);
  }

  Future<PrefRow?> _getRow(String key, String op, int requested) async {
    checkNotInTransaction(_db, op, read: true);
    _checkOpen();
    checkPrefKey(key);
    if (_preloaded) {
      return _checkStored(_rows[key], requested, key, op);
    }
    final stored = await _db.runtime.prefsGet(key);
    return _checkStored(stored, requested, key, op);
  }

  PrefRow? _checkStored(PrefRow? stored, int requested, String key, String op) {
    if (stored == null || stored.kind == requested) {
      return stored;
    }
    throw PrefsTypeException(
      key: key,
      storedKind: prefsKindName(stored.kind),
      requestedKind: prefsKindName(requested),
    );
  }

  PrefRow? _getRowSync(String key, int requested, String desc) {
    _checkOpen();
    _checkPreloaded();
    checkPrefKey(key);
    return _checkStored(_rows[key], requested, key, 'Prefs.${desc}Sync');
  }

  /// Unguarded row read for watch machinery: watches are allowed inside a
  /// transaction body, and their first value reflects committed data.
  Future<PrefRow?> _readRowForWatch(String key) async {
    if (_preloaded) {
      return _rows[key];
    }
    return _db.runtime.prefsGet(key);
  }

  _PrefWatch<T> _machine<T>(String key, T? Function(PrefRow?) decode) =>
      _PrefWatch<T>(
        key,
        decode,
        () => _readRowForWatch(key),
        _addMachine,
        _removeMachine,
      );

  /// Registers [machine] with its key's watch list (on first listen).
  void _addMachine(_PrefWatch<dynamic> machine) {
    (_watches[machine._key] ??= []).add(machine);
  }

  void _removeMachine(_PrefWatch<dynamic> machine) {
    final machines = _watches[machine._key];
    if (machines == null) {
      return;
    }
    machines.remove(machine);
    if (machines.isEmpty) {
      _watches.remove(machine._key);
    }
  }

  Future<void> putSingle<T extends Object>(
    CollectionAdapter<T> adapter,
    String key,
    T value,
    String op,
  ) async {
    checkNotInTransaction(_db, op, read: false);
    _checkOpen();
    checkPrefKey(key);
    final row = (
      kind: prefsModelKind(tableNameFor(adapter.model)),
      bytes: adapter.encode(value),
    );
    await _db.runtime.prefsPut(key, row);
    applyCommitted([(key: key, row: row)]);
  }

  Future<T?> getSingle<T extends Object>(
    CollectionAdapter<T> adapter,
    String key,
    String op,
  ) async {
    checkNotInTransaction(_db, op, read: true);
    _checkOpen();
    checkPrefKey(key);
    final expected = prefsModelKind(tableNameFor(adapter.model));
    final stored = _preloaded ? _rows[key] : await _db.runtime.prefsGet(key);
    if (stored == null) {
      return null;
    }
    if (stored.kind != expected) {
      throw PrefsTypeException(
        key: key,
        storedKind: prefsKindName(stored.kind),
        requestedKind: 'a single model ${adapter.model}',
      );
    }
    return adapter.decode(stored.bytes);
  }

  Future<void> clearSingle<T extends Object>(
    CollectionAdapter<T> adapter,
    String key,
    String op,
  ) async {
    checkNotInTransaction(_db, op, read: false);
    _checkOpen();
    checkPrefKey(key);
    if (await _db.runtime.prefsRemove(key)) {
      applyCommitted([(key: key, row: null)]);
    }
  }

  /// Writes [ops] through the preload map (commit order) and wakes the
  /// watches. Called after every committed mutation: standalone writes and
  /// removals when their awaited call resolves, transaction and batch
  /// mutations once the commit succeeded. A rolled-back transaction never
  /// reaches here.
  @internal
  void applyCommitted(List<PrefWriteOp> ops) {
    for (final (key: key, row: row) in ops) {
      if (_preloaded) {
        if (row == null) {
          _rows.remove(key);
          _models.remove(key);
        } else {
          _rows[key] = row;
        }
      }
      for (final machine in _watches[key] ?? const []) {
        machine.deliver(row);
      }
    }
  }

  /// Completes every watch stream and blocks further calls: the database
  /// is closing.
  @internal
  void close() {
    _closed = true;
    for (final machines in _watches.values) {
      for (final machine in machines) {
        machine.close();
      }
    }
    _watches.clear();
  }

  /// How many prefs watch machines are currently registered (listening) —
  /// a testing counter proving cancels and closes leak no listener.
  @visibleForTesting
  int get debugMachineCount =>
      [for (final machines in _watches.values) machines.length].fold(
        0,
        (a, b) => a + b,
      );

  void _checkOpen() {
    if (_closed) {
      throw StateError('The database is closed');
    }
  }

  void _checkPreloaded() {
    if (!_preloaded) {
      throw StateError(
        'preload() has not run: call await db.prefs.preload() first, or '
        'pass preloadPrefs: true to Cocoon.open',
      );
    }
  }
}
