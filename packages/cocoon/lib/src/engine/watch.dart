import 'dart:async';
import 'dart:typed_data';

import '../path.dart';
import 'changes.dart';
import 'cocoon.dart';
import 'query.dart';
import 'refs.dart';

/// The hub every live watch of one [Cocoon] database registers with.
///
/// Commits are delivered synchronously and cheaply: watchers only mark
/// themselves dirty and re-read on their own schedule, so a commit never
/// waits on watcher I/O.
final class WatchHub {
  final Set<CommitListener> _watchers = {};
  bool _closed = false;

  /// How many watchers are currently registered (listening).
  int get length => _watchers.length;

  /// Registers [watcher]. A no-op once [close] ran.
  void add(CommitListener watcher) {
    if (!_closed) {
      _watchers.add(watcher);
    }
  }

  /// Unregisters [watcher]; its stream stopped (the last listener cancelled).
  void remove(CommitListener watcher) => _watchers.remove(watcher);

  /// Delivers one commit to every watcher.
  void emit(CommitEvent event) {
    if (_closed) {
      return;
    }
    for (final watcher in _watchers.toList()) {
      watcher.onCommit(event);
    }
  }

  /// Completes every watch stream: the database is closing.
  void close() {
    _closed = true;
    for (final watcher in _watchers.toList()) {
      watcher.shutdown();
    }
    _watchers.clear();
  }
}

/// One live watch registered with the [WatchHub].
abstract interface class CommitListener {
  /// Called once per committed transaction, after the cache was updated.
  void onCommit(CommitEvent event);

  /// Completes the watch stream. Called when the database closes.
  void shutdown();
}

/// A live `DocRef.watch` stream: re-reads its document when a commit touched
/// the exact path, and skips emissions whose canonical bytes did not change.
final class DocWatch<T extends Object> implements CommitListener {
  DocWatch(this._db, this._ref, this._table);

  final Cocoon _db;
  final DocRef<T> _ref;
  final String _table;

  late final StreamController<DocSnapshot<T>?> _controller =
      StreamController<DocSnapshot<T>?>.broadcast(
        onListen: _onListen,
        onCancel: _onCancel,
      );

  /// The stream; work starts on the first listen and stops when the last
  /// listener cancels.
  Stream<DocSnapshot<T>?> get stream => _controller.stream;

  /// Canonical wire bytes of the last emitted value (`null` when the
  /// document was absent).
  Uint8List? _lastBytes;
  bool _registered = false;
  bool _pumping = false;
  bool _dirty = false;

  void _onListen() {
    if (!_registered) {
      _db.watchHub.add(this);
      _registered = true;
    }
    _pump(force: true);
  }

  void _onCancel() {
    if (_registered) {
      _db.watchHub.remove(this);
      _registered = false;
    }
  }

  @override
  void onCommit(CommitEvent event) {
    for (final (table, path, _) in event.touched) {
      if (table == _table && path == _ref.path.path) {
        _dirty = true;
        _pump();
        return;
      }
    }
  }

  @override
  void shutdown() {
    _controller.close();
  }

  /// Re-reads and emits, coalescing commits that arrive mid-flight: at most
  /// one more re-read happens after the current one finishes.
  Future<void> _pump({bool force = false}) async {
    if (_controller.isClosed) {
      return;
    }
    if (_pumping) {
      // Already re-reading; _dirty makes it loop once more afterwards.
      return;
    }
    _pumping = true;
    var mustEmit = force;
    try {
      while (!_controller.isClosed && (mustEmit || _dirty)) {
        _dirty = false;
        final snapshot = await _db.getDoc(_ref);
        if (_controller.isClosed) {
          return;
        }
        final bytes = snapshot == null
            ? null
            : _ref.adapter.encode(snapshot.data);
        if (mustEmit || !_bytesEqual(bytes, _lastBytes)) {
          _lastBytes = bytes;
          _controller.add(snapshot);
        }
        mustEmit = false;
      }
    } on Object catch (error, stackTrace) {
      if (!_controller.isClosed) {
        _controller.addError(error, stackTrace);
      }
    } finally {
      _pumping = false;
    }
  }
}

/// A live query watch: re-runs its query when a commit touched the query's
/// table (and, for scoped queries, a path inside the parent scope), and
/// skips pages whose paths and bytes equal the previous page's.
final class QueryWatch<T extends Object> implements CommitListener {
  QueryWatch(this._db, this._query, this._table, this._scopePath);

  final Cocoon _db;
  final CocoonQuery<T> _query;
  final String _table;

  /// The parent collection path of a subcollection query, or `null` for a
  /// collection-group query (every path of the table then matches).
  final CollectionPath? _scopePath;

  late final StreamController<QueryPage<T>> _controller =
      StreamController<QueryPage<T>>.broadcast(
        onListen: _onListen,
        onCancel: _onCancel,
      );

  /// The stream; work starts on the first listen and stops when the last
  /// listener cancels.
  Stream<QueryPage<T>> get stream => _controller.stream;

  /// Documents and canonical bytes of the last emitted page.
  List<DocSnapshot<T>>? _lastDocs;
  List<Uint8List>? _lastBytes;
  bool _registered = false;
  bool _pumping = false;
  bool _dirty = false;

  void _onListen() {
    if (!_registered) {
      _db.watchHub.add(this);
      _registered = true;
    }
    _pump(force: true);
  }

  void _onCancel() {
    if (_registered) {
      _db.watchHub.remove(this);
      _registered = false;
    }
  }

  @override
  void onCommit(CommitEvent event) {
    for (final (table, path, _) in event.touched) {
      if (table != _table) {
        continue;
      }
      final scope = _scopePath;
      if (scope == null || path.startsWith('${scope.path}/')) {
        _dirty = true;
        _pump();
        return;
      }
    }
  }

  @override
  void shutdown() {
    _controller.close();
  }

  /// Re-runs and emits, coalescing commits that arrive mid-flight: at most
  /// one more re-run happens after the current one finishes.
  Future<void> _pump({bool force = false}) async {
    if (_controller.isClosed) {
      return;
    }
    if (_pumping) {
      // Already re-running; _dirty makes it loop once more afterwards.
      return;
    }
    _pumping = true;
    var mustEmit = force;
    try {
      while (!_controller.isClosed && (mustEmit || _dirty)) {
        _dirty = false;
        final (page, bytes) = await _db.runQueryWithBytes(_query);
        if (_controller.isClosed) {
          return;
        }
        if (mustEmit || !_sameAsLast(page, bytes)) {
          _lastDocs = page.docs;
          _lastBytes = bytes;
          _controller.add(page);
        }
        mustEmit = false;
      }
    } on Object catch (error, stackTrace) {
      if (!_controller.isClosed) {
        _controller.addError(error, stackTrace);
      }
    } finally {
      _pumping = false;
    }
  }

  /// Whether [page] (with the stored [bytes] of its documents) is
  /// indistinguishable from the last emitted page.
  bool _sameAsLast(QueryPage<T> page, List<Uint8List> bytes) {
    final lastDocs = _lastDocs;
    final lastBytes = _lastBytes;
    if (lastDocs == null || lastBytes == null) {
      return false;
    }
    if (lastDocs.length != page.docs.length ||
        lastBytes.length != bytes.length) {
      return false;
    }
    for (var i = 0; i < bytes.length; i++) {
      if (lastDocs[i].ref.path.path != page.docs[i].ref.path.path) {
        return false;
      }
      if (!_bytesEqual(lastBytes[i], bytes[i])) {
        return false;
      }
    }
    return true;
  }
}

/// Byte equality over canonical wire bytes; `null` means "document absent".
bool _bytesEqual(Uint8List? a, Uint8List? b) {
  if (identical(a, b)) {
    return true;
  }
  if (a == null || b == null || a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}
