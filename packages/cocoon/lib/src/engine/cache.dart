import 'dart:collection';

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

/// Cache updates collected while a write transaction runs, applied only
/// after the transaction commits. If the transaction throws, the stage is
/// simply discarded, so the cache never reflects uncommitted writes.
final class CacheStage {
  final List<void Function(DocumentCache)> _operations = [];

  /// Stages a decoded value for [path].
  void put(String path, Object value) =>
      _operations.add((cache) => cache.put(path, value));

  /// Stages the eviction of [path] and its subtree.
  void evictSubtree(String path) =>
      _operations.add((cache) => cache.evictSubtree(path));

  /// Applies every staged update to [cache], in write order.
  void applyTo(DocumentCache cache) {
    for (final operation in _operations) {
      operation(cache);
    }
  }
}
