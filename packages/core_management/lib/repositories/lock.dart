/// Abstract base class for lock repositories that handle distributed locking.
/// 
/// ## Implementation Guidelines
/// 
/// ### Key Concepts
/// - A lock is identified by a unique `key`
/// - Each lock has an expiration time to prevent deadlocks
/// - Locks should be released when no longer needed
/// 
/// ### Implementation Requirements
/// 1. **Thread Safety**: Ensure all operations are thread-safe.
/// 2. **Atomicity**: Operations should be atomic to prevent race conditions.
/// 3. **Expiration Handling**: Clean up expired locks to prevent resource leaks.
/// 4. **Error Handling**: Handle potential errors from the underlying storage.
/// 
/// ### Example Implementation
/// ```dart
/// class MyLockRepository implements LockRepository {
///   final Database _database;
///   
///   MyLockRepository(this._database);
///   
///   @override
///   Future<void> createOrUpdateLock(String key, DateTime expiryTime) async {
///     await _database.execute(
///       'INSERT OR REPLACE INTO locks (key, expiry) VALUES (?, ?)',
///       [key, expiryTime.toIso8601String()],
///     );
///   }
///   
///   // Implement other methods...
/// }/// ```
/// 
/// ## Best Practices
/// - Use `watchLockRelease` for efficient waiting when available
/// - Always release locks in a `finally` block
/// - Set reasonable expiration times
abstract class LockRepository {
  /// Creates or updates a lock entry.
  /// 
  /// If a lock with the given [key] already exists, its expiry time will be updated.
  /// 
  /// Parameters:
  /// - [key]: Unique identifier for the lock
  /// - [expiryTime]: When the lock should automatically expire
  /// 
  /// Throws:
  /// - `Exception` if the lock cannot be created/updated
  Future<void> createOrUpdateLock(String key, DateTime expiryTime);

  /// Gets the expiry time for the lock with the given [key].
  /// 
  /// Returns:
  /// - `DateTime` representing when the lock expires, or
  /// - `null` if no active lock exists for the key
  /// 
  /// Note:
  /// - Should automatically clean up expired locks when found
  Future<DateTime?> getLockExpiry(String key);

  /// Deletes the lock with the given [key].
  /// 
  /// Returns:
  /// - `true` if a lock was deleted
  /// - `false` if no lock existed for the key
  /// 
  /// Note:
  /// - Should be idempotent (safe to call multiple times)
  Future<bool> deleteLock(String key);

  /// Gets all current non-expired locks.
  /// 
  /// Returns:
  /// - A map of lock keys to their expiry times
  /// - Empty map if no locks exist
  /// 
  /// Note:
  /// - Should only return non-expired locks
  /// - Should clean up any expired locks found
  Future<Map<String, DateTime>> getAllLocks();

  /// Optional: Subscribe to lock release events.
  /// 
  /// If implemented, this allows for more efficient waiting on lock release.
  /// The stream should emit an event when the specified lock is released.
  /// 
  /// Returns:
  /// - A `Stream` that emits when the lock is released, or
  /// - `null` if this feature is not supported
  /// 
  /// Example:
  /// ```dart
  /// final stream = repo.watchLockRelease('my-lock');
  /// if (stream != null) {
  ///   await stream.first;
  /// }
  /// ```
  Stream<void>? watchLockRelease(String key) => null;
}