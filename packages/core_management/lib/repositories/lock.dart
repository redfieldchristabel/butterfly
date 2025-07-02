import 'dart:async';

/// Interface for persistent lock storage.
///
/// Implement this interface to provide persistent storage for locks.
/// All methods are asynchronous to allow for network or disk I/O.
abstract class LockPersistence {
  /// Creates or updates a lock with the given [key] and [expiryTime].
  FutureOr<void> createOrUpdateLock(String key, DateTime expiryTime);

  /// Gets the expiry time of the lock with the given [key].
  ///
  /// Returns `null` if the lock doesn't exist or has expired.
  /// Implementations should clean up expired locks when encountered.
  FutureOr<DateTime?> getLockExpiry(String key);

  /// Deletes the lock with the given [key].
  ///
  /// Returns `true` if the lock existed and was deleted.
  FutureOr<bool> deleteLock(String key);

  /// Watches for the release of the lock with the given [key].
  ///
  /// Returns a stream that emits an event when the lock is released.
  /// Returns `null` if watching is not supported.
  Stream<void>? watchLockRelease(String key);

  /// Cleans up all expired locks.
  FutureOr<void> cleanupExpiredLocks();

  /// Releases all resources used by this persistence layer.
  void dispose();
}
