import 'dart:collection';
import 'dart:typed_data';

import 'changes.dart' show ChangeOp, TouchedChange;

/// Bounded LRU cache of recently read, decoded documents, keyed by full path.
///
/// Keeps hot-document reads out of SQLite while RAM stays capped: when
/// [capacity] entries are exceeded the least recently used entry is dropped.
/// A capacity of 0 disables the cache entirely.
///
/// One cache belongs to exactly one `Cocoon` instance, which must own the
/// database file (no multi-process writers), so cached values can never go
/// stale behind the engine's back: every write and delete (including cascade
/// deletes) updates or evicts the affected paths.
///
/// Entries may hold a decoded value or an [EncodedDoc]: writes cache the
/// document's encoded bytes and the first cache read decodes them once (the
/// read-your-writes guarantee is then byte-exact — the cached bytes are the
/// stored bytes). [DocumentCache] itself never interprets entries.
final class DocumentCache {
  /// Builds a cache holding at most [capacity] documents.
  DocumentCache(this.capacity) : _entries = LinkedHashMap();

  /// The maximum number of cached documents; 0 disables caching.
  final int capacity;

  final LinkedHashMap<String, Object> _entries;

  /// The number of cached documents.
  int get length => _entries.length;

  /// Returns the cached value for [path] and marks it most recently used, or
  /// `null` on a miss.
  Object? get(String path) {
    if (capacity <= 0) {
      return null;
    }
    final value = _entries.remove(path);
    if (value != null) {
      _entries[path] = value;
    }
    return value;
  }

  /// Caches [value] for [path] as the most recently used entry.
  void put(String path, Object value) {
    if (capacity <= 0) {
      return;
    }
    _entries.remove(path);
    _entries[path] = value;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// Evicts [path] and its whole subtree (`path/...`), which is what a
  /// cascade delete removes. Paths of prefix-sibling documents (`a1` vs
  /// `a10`) are not affected.
  void evictSubtree(String path) {
    if (capacity <= 0) {
      return;
    }
    _entries.remove(path);
    final prefix = '$path/';
    _entries.removeWhere((key, _) => key.startsWith(prefix));
  }
}

/// Encoded document bytes held by a [DocumentCache] entry, pending the first
/// read that decodes them.
///
/// The wrapper (rather than a bare `Uint8List`) keeps entries unambiguous: a
/// decoded value may itself be a `Uint8List`.
final class EncodedDoc {
  const EncodedDoc(this.bytes);

  /// The document's canonical wire bytes, exactly as stored.
  final Uint8List bytes;
}

/// Cache updates collected while a write transaction runs, applied only
/// after the transaction commits. If the transaction throws, the stage is
/// simply discarded, so the cache never reflects uncommitted writes.
final class CacheStage {
  final List<void Function(DocumentCache)> _operations = [];
  final Set<TouchedChange> _touched = {};

  /// Stages a decoded value for [path].
  void put(String path, Object value) =>
      _operations.add((cache) => cache.put(path, value));

  /// Stages the eviction of [path] and its subtree.
  void evictSubtree(String path) =>
      _operations.add((cache) => cache.evictSubtree(path));

  /// Records that this transaction touched a document (its SQL [table],
  /// full [path] and the [op] performed). The distinct set is reported once
  /// after the commit succeeds and drives the watch notifications.
  void touched(String table, String path, ChangeOp op) =>
      _touched.add((table, path, op));

  /// The distinct (table, path, op) set this transaction touched, taking it:
  /// the stage is single-use per transaction and the set is only reported
  /// for committed transactions.
  Set<TouchedChange> takeTouched() {
    if (_touched.isEmpty) {
      return const {};
    }
    final taken = Set<TouchedChange>.of(_touched);
    _touched.clear();
    return taken;
  }

  /// Applies every staged update to [cache], in write order.
  void applyTo(DocumentCache cache) {
    for (final operation in _operations) {
      operation(cache);
    }
  }
}
