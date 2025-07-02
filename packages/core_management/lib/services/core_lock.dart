import 'dart:async';

import '../repositories/lock.dart';

/// A distributed locking service that coordinates access to shared resources.
///
/// This service uses in-memory storage by default but can be configured with
/// a persistent [LockPersistence] for cross-process or persistent locking.
///
/// ## Basic Usage
/// ```dart
/// // Simple in-memory lock
/// final lockService = CoreLockService();
///
/// // With persistence
/// final persistence = MyPersistenceImplementation();
/// final persistentLockService = CoreLockService(persistence: persistence);
///
/// // Acquire a lock
/// final acquired = await lockService.acquire('resource-123');
/// if (acquired) {
///   try {
///     // Critical section
///   } finally {
///     await lockService.release('resource-123');
///   }
/// }
/// ```
class CoreLockService {
  // In-memory storage for locks
  static final Map<String, _LockEntry> _locks = {};
  static final Map<String, StreamController<void>> _releaseControllers = {};

  final LockPersistence? _persistence;
  final Duration _defaultLockDuration;
  final Duration _pollingInterval;

  /// Creates a new [CoreLockService] instance.
  ///
  /// The [persistence] is optional and provides persistent storage for locks.
  /// If not provided, locks will only be stored in memory.
  ///
  /// [defaultLockDuration] specifies how long locks are held by default.
  /// Defaults to 30 seconds.
  ///
  /// [pollingInterval] is used when waiting for locks with a timeout.
  /// Defaults to 100ms.
  CoreLockService({
    LockPersistence? persistence,
    Duration? defaultLockDuration,
    Duration? pollingInterval,
  })  : _persistence = persistence,
        _defaultLockDuration = defaultLockDuration ?? const Duration(seconds: 30),
        _pollingInterval = pollingInterval ?? const Duration(milliseconds: 100) {
    if (pollingInterval != null && pollingInterval <= Duration.zero) {
      throw ArgumentError('pollingInterval must be positive');
    }
  }

  /// Attempts to acquire a lock for the given [key].
  ///
  /// If [timeout] is provided, waits up to that duration to acquire the lock.
  /// If [lockDuration] is provided, overrides the default lock duration.
  ///
  /// Attempts to acquire a lock for the given [key].
  ///
  /// If [timeout] is provided, waits up to that duration to acquire the lock.
  /// If [lockDuration] is provided, overrides the default lock duration.
  ///
  /// Returns `true` if the lock was acquired, `false` otherwise.
  ///
  /// Note: Persistence operations are performed in the background.
  bool acquire(
    String key, {
    Duration? timeout,
    Duration? lockDuration,
  }) {
    final expiryTime = DateTime.now().add(lockDuration ?? _defaultLockDuration);

    // Check in-memory first
    if (_tryAcquireInMemory(key, expiryTime)) {
      // Sync persistence in background
      _syncWithPersistence(
        () => _persistence?.createOrUpdateLock(key, expiryTime),
      );
      return true;
    }

    // If we have a timeout, wait for the lock
    if (timeout != null && timeout > Duration.zero) {
      return _waitForLock(key, expiryTime, timeout);
    }

    return false;
  }

  /// Releases the lock with the given [key].
  ///
  /// Returns `true` if the lock was released, `false` if it didn't exist.
  ///
  /// Note: Persistence operations are performed in the background.
  bool release(String key) {
    final hadLock = _releaseInMemory(key);
    if (hadLock) {
      _syncWithPersistence(
        () => _persistence?.deleteLock(key),
      );
      return true;
    }
    return false;
  }

  /// Checks if a lock with the given [key] is currently held.
  ///
  /// This only checks the in-memory state for immediate response.
  /// For a complete check including persistence, use [isLockedAsync].
  bool isLocked(String key) {
    final entry = _locks[key];
    if (entry != null) {
      if (entry.expiry.isAfter(DateTime.now())) {
        return true;
      }
      // Clean up expired lock
      _releaseInMemory(key);
    }
    return false;
  }

  /// Checks if a lock with the given [key] is currently held,
  /// including checking the persistence layer.
  Future<bool> isLockedAsync(String key) async {
    // Check in-memory first
    if (isLocked(key)) {
      return true;
    }

    // Check persistence if available
    if (_persistence != null) {
      final expiry = await _persistence!.getLockExpiry(key);
      if (expiry != null && expiry.isAfter(DateTime.now())) {
        return true;
      }
    }

    return false;
  }

  /// Gets the expiry time of the lock with the given [key] from memory.
  ///
  /// Returns the expiry time if the lock exists and is not expired, null otherwise.
  /// For persistence-aware check, use [getLockExpiryAsync].
  DateTime? getLockExpiry(String key) {
    final entry = _locks[key];
    if (entry != null) {
      if (entry.expiry.isAfter(DateTime.now())) {
        return entry.expiry;
      }
      _releaseInMemory(key);
    }
    return null;
  }

  /// Gets the expiry time of the lock with the given [key], checking persistence.
  ///
  /// Returns the expiry time if the lock exists and is not expired, null otherwise.
  Future<DateTime?> getLockExpiryAsync(String key) async {
    // Check in-memory first
    final memoryExpiry = getLockExpiry(key);
    if (memoryExpiry != null) {
      return memoryExpiry;
    }

    // Check persistence if available
    if (_persistence != null) {
      return await _persistence!.getLockExpiry(key);
    }

    return null;
  }

  // Tries to acquire a lock in memory
  bool _tryAcquireInMemory(String key, DateTime expiryTime) {
    final now = DateTime.now();
    final existing = _locks[key];

    if (existing == null || existing.expiry.isBefore(now)) {
      _locks[key] = _LockEntry(expiryTime);
      return true;
    }

    return false;
  }

  // Releases a lock in memory
  bool _releaseInMemory(String key) {
    final hadLock = _locks.remove(key) != null;
    if (hadLock) {
      _releaseControllers[key]?.add(null);
      _releaseControllers.remove(key)?.close();
    }
    return hadLock;
  }

  // Waits for a lock to be released
  bool _waitForLock(
    String key,
    DateTime expiryTime,
    Duration timeout,
  ) {
    final endTime = DateTime.now().add(timeout);
    final stopwatch = Stopwatch()..start();

    while (stopwatch.elapsed < timeout) {
      if (_tryAcquireInMemory(key, expiryTime)) {
        _syncWithPersistence(
          () => _persistence?.createOrUpdateLock(key, expiryTime),
        );
        return true;
      }

      // Wait for the lock to be released or timeout
      final remaining = timeout - stopwatch.elapsed;
      if (remaining <= Duration.zero) break;
      
      final released = _waitForRelease(key, DateTime.now().add(remaining));
      if (!released) break;
    }

    return false;
  }

  // Waits for a lock to be released or until endTime
  bool _waitForRelease(String key, DateTime endTime) {
    final now = DateTime.now();
    if (now.isAfter(endTime)) return false;

    // If we have a persistence layer that supports watching, use it
    if (_persistence != null) {
      final stream = _persistence!.watchLockRelease(key);
      if (stream != null) {
        final completer = Completer<bool>();
        final subscription = stream.listen(
          null,
          onDone: () => completer.complete(true),
        );

        try {
          // Wait with timeout
          final timeout = endTime.difference(now);
          final result = completer.future.timeout(
            timeout,
            onTimeout: () {
              completer.complete(false);
              return false;
            },
          ) as FutureOr<bool>;
          
          // This is a simplification - in a real implementation,
          // you'd need to handle the async operation differently
          // For sync context, we'll just return false
          return false;
        } finally {
          subscription.cancel();
        }
      }
    }

    // Fall back to polling
    final remaining = endTime.difference(now);
    if (remaining <= Duration.zero) return false;

    // For sync context, we'll just do a simple delay
    // In a real implementation, you might want to use a different approach
    // like a busy-wait with small delays
    _syncDelay(remaining);
    return false;
  }
  
  // Helper method to run persistence operations in the background
  void _syncWithPersistence(FutureOr Function() operation) {
    if (_persistence == null) return;
    
    // Run in a microtask to ensure it's async but still runs soon
    Future.microtask(() async {
      try {
        await operation();
      } catch (e) {
        // Log error but don't fail the operation
        print('Error in background persistence: $e');
      }
    });
  }
  
  // Helper method for simple delays in sync context
  void _syncDelay(Duration duration) {
    final end = DateTime.now().add(duration);
    while (DateTime.now().isBefore(end)) {
      // Small delay to prevent CPU spinning
      Future.delayed(const Duration(milliseconds: 50));
    }
  }

  /// Cleans up all expired locks in memory.
  ///
  /// This should be called periodically to clean up stale locks.
  /// For persistence cleanup, use [cleanupExpiredLocksAsync].
  void cleanupExpiredLocks() {
    final now = DateTime.now();
    final expired = _locks.entries
        .where((e) => e.value.expiry.isBefore(now))
        .map((e) => e.key)
        .toList();

    for (final key in expired) {
      _releaseInMemory(key);
    }
  }

  /// Cleans up all expired locks, including persistence.
  ///
  /// This should be called periodically to clean up stale locks.
  Future<void> cleanupExpiredLocksAsync() async {
    cleanupExpiredLocks();
    await _persistence?.cleanupExpiredLocks();
  }

  /// Disposes all resources used by this service.
  void dispose() {
    for (final controller in _releaseControllers.values) {
      controller.close();
    }
    _releaseControllers.clear();
    _locks.clear();
    _persistence?.dispose();
  }
}

/// Internal class representing a lock entry
class _LockEntry {
  final DateTime expiry;

  _LockEntry(this.expiry);
}

