import 'dart:async' show StreamController;

import '../../../repositories/lock.dart';

class InMemoryLockRepository implements LockRepository {
  final Map<String, DateTime> _locks = {};
  final Map<String, StreamController<void>> _lockReleaseControllers = {};

  @override
  Future<void> createOrUpdateLock(String key, DateTime expiryTime) async {
    _locks[key] = expiryTime;
  }

  @override
  Future<DateTime?> getLockExpiry(String key) async {
    final expiry = _locks[key];
    if (expiry != null && expiry.isBefore(DateTime.now())) {
      // Clean up expired lock
      await deleteLock(key);
      return null;
    }
    return expiry;
  }

  @override
  Future<bool> deleteLock(String key) async {
    final existed = _locks.containsKey(key);
    if (existed) {
      _locks.remove(key);
      // Notify any listeners that the lock was released
      _lockReleaseControllers[key]?.add(null);
      await _lockReleaseControllers[key]?.close();
      _lockReleaseControllers.remove(key);
    }
    return existed;
  }

  @override
  Future<Map<String, DateTime>> getAllLocks() async {
    // Clean up any expired locks
    final expiredKeys = _locks.entries
        .where((entry) => entry.value.isBefore(DateTime.now()))
        .map((e) => e.key)
        .toList();

    for (final key in expiredKeys) {
      await deleteLock(key);
    }

    return Map.unmodifiable(_locks);
  }

  @override
  Stream<void>? watchLockRelease(String key) {
    return _lockReleaseControllers
        .putIfAbsent(key, () => StreamController<void>.broadcast())
        .stream;
  }

  /// Clears all locks - for testing purposes
  void clear() {
    _locks.clear();
    for (final controller in _lockReleaseControllers.values) {
      controller.close();
    }
    _lockReleaseControllers.clear();
  }
}
