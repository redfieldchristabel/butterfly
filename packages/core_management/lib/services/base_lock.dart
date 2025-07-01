import 'dart:async';

import '../repositories/lock.dart';

/// A distributed locking service that coordinates access to shared resources.
///
/// ## Overview
/// `CoreLockService` provides a high-level API for managing distributed locks using
/// a pluggable [LockRepository] for storage. It handles lock acquisition, release,
/// and automatic expiration to prevent deadlocks.
///
/// ## Features
/// - **Distributed Locking**: Coordinate access across multiple processes/instances
/// - **Automatic Expiration**: Locks automatically expire after a configurable duration
/// - **Wait with Timeout**: Optionally wait for a lock to become available
/// - **Lock Extension**: Extend lock duration if needed
/// - **Thread-Safe**: Safe for concurrent use
///
/// ## Basic Usage
/// ```dart
/// // Create a repository (e.g., InMemoryLockRepository, DatabaseLockRepository)
/// final repository = InMemoryLockRepository();
///
/// // Create the lock service
/// final lockService = CoreLockService(
///   repository: repository,
///   defaultLockDuration: Duration(seconds: 30),
/// );
///
/// // Acquire a lock
/// final acquired = await lockService.acquireLock('resource-123');
/// if (acquired) {
///   try {
///     // Critical section - only one caller can be here at a time
///     await processCriticalResource();
///   } finally {
///     // Always release the lock in a finally block
///     await lockService.releaseLock('resource-123');
///   }
/// }
/// ```
///
/// ## Lock Expiration
/// Locks automatically expire after the specified duration to prevent deadlocks.
/// The default duration is 30 seconds but can be customized:
/// ```dart
/// // Acquire a lock with custom duration
/// await lockService.acquireLock('resource-123',
///   lockDuration: Duration(minutes: 5));
/// ```
///
/// ## Waiting for Locks
/// You can wait for a lock to become available:
/// ```dart
/// // Wait up to 10 seconds for the lock
/// final acquired = await lockService.acquireLock(
///   'resource-123',
///   timeout: Duration(seconds: 10),
/// );
/// ```
///
/// ## Best Practices
/// 1. Always release locks in a `finally` block
/// 2. Set reasonable lock durations
/// 3. Use descriptive lock keys
/// 4. Handle lock acquisition failures gracefully
/// 5. Consider using `getLockTimeRemaining()` for debugging
class CoreLockService {
  final LockRepository _repository;
  final Duration _defaultLockDuration;
  final Duration _pollingInterval;
  final Map<String, bool> _waitingLocks = {};

  /// Creates a new [CoreLockService] instance.
  ///
  /// The [repository] is used for lock storage. Use [InMemoryLockRepository] for
  /// single-process scenarios or implement a custom repository for distributed
  /// scenarios.
  ///
  /// The [defaultLockDuration] is the default duration before a lock expires.
  /// Defaults to 30 seconds if not specified.
  ///
  /// The [pollingInterval] is the interval to poll for lock availability when
  /// waiting with a timeout. Defaults to 100ms. Must be positive.
  CoreLockService({
    required LockRepository repository,
    Duration? defaultLockDuration,
    Duration? pollingInterval,
  })  : _repository = repository,
        _defaultLockDuration =
            defaultLockDuration ?? const Duration(seconds: 30),
        _pollingInterval =
            pollingInterval ?? const Duration(milliseconds: 100) {
    if (pollingInterval != null && pollingInterval <= Duration.zero) {
      throw ArgumentError('pollingInterval must be positive');
    }
  }

  /// Acquires a lock with the given [key].
  ///
  /// Attempts to acquire a lock for [key].
  ///
  /// If the lock is already held, waits for it to be released or until [timeout]
  /// elapses. If [timeout] is `null`, returns immediately if the lock is not
  /// available.
  ///
  /// The [lockDuration] specifies how long the lock should be held before
  /// automatically expiring. Defaults to the duration specified in the
  /// constructor.
  ///
  /// Returns `true` if the lock was acquired, or `false` if the lock could not
  /// be acquired within the given [timeout].
  ///
  /// Throws a [StateError] if called recursively for the same key, or an
  /// [Exception] if there's an error communicating with the lock repository.
  ///
  /// ```dart
  /// final acquired = await lockService.acquireLock(
  ///   'user-profile-123',
  ///   timeout: Duration(seconds: 5),
  ///   lockDuration: Duration(minutes: 1),
  /// );
  /// if (acquired) {
  ///   // Critical section
  /// }
  /// ```
  Future<bool> acquireLock(
    String key, {
    Duration? timeout,
    Duration? lockDuration,
  }) async {
    if (_waitingLocks[key] == true) {
      throw StateError('Already waiting for lock: $key');
    }

    _waitingLocks[key] = true;
    try {
      final expiryTime =
          DateTime.now().add(lockDuration ?? _defaultLockDuration);

      // Try to acquire the lock immediately first
      if (await _tryAcquireLock(key, expiryTime)) {
        return true;
      }

      // If lock is held, wait for it to be released or timeout
      if (timeout != null && timeout > Duration.zero) {
        final acquired = await _waitForLockRelease(key, expiryTime, timeout);
        if (acquired) return true;
      }

      return false;
    } finally {
      _waitingLocks.remove(key);
    }
  }

  Future<bool> _tryAcquireLock(String key, DateTime expiryTime) async {
    final existingExpiry = await _repository.getLockExpiry(key);

    if (existingExpiry == null || existingExpiry.isBefore(DateTime.now())) {
      // No lock or expired lock, try to acquire it
      await _repository.createOrUpdateLock(key, expiryTime);

      // Double check if we got the lock (in case of race conditions)
      final currentExpiry = await _repository.getLockExpiry(key);
      if (currentExpiry == expiryTime) {
        return true;
      }
    }

    return false;
  }

  Future<bool> _waitForLockRelease(
      String key, DateTime expiryTime, Duration timeout) async {
    final completer = Completer<bool>();
    final timer = Timer(timeout, () => completer.complete(false));

    // Try to use efficient watch mechanism if available
    final releaseStream = _repository.watchLockRelease(key);
    if (releaseStream != null) {
      final subscription = releaseStream.listen(
        null,
        onDone: () async {
          if (await _tryAcquireLock(key, expiryTime)) {
            if (!completer.isCompleted) {
              timer.cancel();
              completer.complete(true);
            }
          }
        },
      );

      // Also check immediately in case we missed the event
      if (await _tryAcquireLock(key, expiryTime)) {
        subscription.cancel();
        timer.cancel();
        return true;
      }

      final result = await completer.future;
      subscription.cancel();
      return result;
    }

    // Fallback to polling
    final endTime = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(endTime)) {
      if (await _tryAcquireLock(key, expiryTime)) {
        timer.cancel();
        return true;
      }
      await Future.delayed(_pollingInterval);
    }

    timer.cancel();
    return false;
  }

  /// Releases the lock associated with the given [key].
  ///
  /// Releases the lock associated with [key].
  ///
  /// Returns `true` if the lock was released, or `false` if no lock existed
  /// for [key].
  ///
  /// Always call this method in a `finally` block after acquiring a lock to
  /// ensure proper cleanup, even if an error occurs.
  ///
  /// ```dart
  /// try {
  ///   await criticalOperation();
  /// } finally {
  ///   await lockService.releaseLock('resource-123');
  /// }
  /// ```
  Future<bool> releaseLock(String key) async {
    return _repository.deleteLock(key);
  }

  /// Returns whether a lock with [key] is currently held and valid.
  ///
  /// The result is only valid at the time of the call, as the lock state may
  /// change immediately after this method returns.
  ///
  /// ```dart
  /// if (await lockService.isLocked('resource-123')) {
  ///   print('Resource is currently locked');
  /// }
  /// ```
  Future<bool> isLocked(String key) async {
    final expiry = await _repository.getLockExpiry(key);
    return expiry != null && expiry.isAfter(DateTime.now());
  }

  /// Extends the duration of the lock with [key].
  ///
  /// The [extension] specifies how much longer to hold the lock. Defaults to
  /// the default lock duration.
  ///
  /// Returns `true` if the lock was extended, or `false` if the lock doesn't
  /// exist or has expired.
  ///
  /// ```dart
  /// final extended = await lockService.extendLock(
  ///   'long-running-job',
  ///   extension: Duration(seconds: 30),
  /// );
  /// if (!extended) {
  ///   // Handle case where lock couldn't be extended
  /// }
  /// ```
  Future<bool> extendLock(String key, {Duration? extension}) async {
    final expiry = await _repository.getLockExpiry(key);
    if (expiry == null || expiry.isBefore(DateTime.now())) {
      return false;
    }

    final newExpiry = expiry.add(extension ?? _defaultLockDuration);
    await _repository.createOrUpdateLock(key, newExpiry);
    return true;
  }

  /// Returns the time remaining until the lock with [key] expires.
  ///
  /// Returns the remaining [Duration] if the lock exists and is still valid,
  /// or `null` if the lock doesn't exist or has expired.
  ///
  /// ```dart
  /// final remaining = await lockService.getLockTimeRemaining('resource-123');
  /// if (remaining != null) {
  ///   print('Lock will expire in ${remaining.inSeconds} seconds');
  /// }
  /// ```
  Future<Duration?> getLockTimeRemaining(String key) async {
    final expiry = await _repository.getLockExpiry(key);
    if (expiry == null || expiry.isBefore(DateTime.now())) {
      return null;
    }
    return expiry.difference(DateTime.now());
  }
}
