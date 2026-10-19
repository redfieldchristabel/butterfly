/// Links your app's user model to the Firebase Auth account it belongs to.
///
/// `FirebaseAuthManagementRepository` requires its user type to mix this
/// in. Before reusing a cached user it compares [firebaseUid] with the
/// signed-in account's `User.uid`, so when a different account signs in it
/// fetches fresh data instead of serving someone else's cached profile.
///
/// ```dart
/// class AppUser with FirebaseUser {
///   final String id;
///   final String role;
///   final int coins;
///
///   AppUser({required this.id, required this.role, required this.coins});
///
///   @override
///   String get firebaseUid => id;
/// }
/// ```
mixin FirebaseUser {
  /// The Firebase Auth uid (`User.uid`) this user belongs to.
  ///
  /// Point it at wherever your model keeps the uid: `id`, `uid`,
  /// `firebaseId`... It must equal the `User.uid` passed to `fetchUser`.
  /// If it doesn't, the cached user never matches and every launch fetches
  /// the user again.
  String get firebaseUid;
}
