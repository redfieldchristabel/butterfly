import 'dart:async';

import 'package:auth_management/auth_management.dart';
import 'package:auth_management_firebase/src/mixins/firebase_user.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show protected, visibleForOverriding;

/// Firebase Auth as the identity provider for your app's user model [T].
///
/// Firebase Auth only knows the basics (uid, email, display name, phone).
/// Implement [fetchUser] to load the rest (role, coins, profile...) from
/// Firestore or anywhere else. Your model mixes in [FirebaseUser] so a
/// cached user is never served to a different account:
///
/// ```dart
/// class AppUser with FirebaseUser {
///   AppUser({required this.uid, required this.role, required this.coins});
///
///   final String uid;
///   final String role;
///   final int coins;
///
///   @override
///   String get firebaseUid => uid;
/// }
///
/// class AuthService extends FirebaseAuthManagementRepository<AppUser> {
///   @override
///   AuthManagementDatabaseRepository<AppUser> get dbRepo => hiveRepo;
///
///   @override
///   Future<AppUser> fetchUser(User firebaseUser) async {
///     final doc = await FirebaseFirestore.instance
///         .doc('users/${firebaseUser.uid}')
///         .get();
///     return AppUser.fromJson({'uid': firebaseUser.uid, ...?doc.data()});
///   }
/// }
/// ```
///
/// Then read the user with [getUser], [streamUser] or [currentUser].
abstract class FirebaseAuthManagementRepository<T extends FirebaseUser>
    extends IdentityAuthRepository<User, T> {
  final FirebaseAuth auth = FirebaseAuth.instance;

  /// Also see [FirebaseAuth.signInWithEmailAndPassword].
  Future<UserCredential> signInWithEmailAndPassword(
          String email, String password) =>
      auth.signInWithEmailAndPassword(email: email, password: password);

  /// Signs out of Firebase, then clears the cached user and provider state.
  @override
  Future<void> signOut() async {
    await auth.signOut();
    await super.signOut();
  }

  /// Loads your app's user model [T] for the signed-in [firebaseUser].
  ///
  /// **You implement this.** [firebaseUser] gives you the uid, email and
  /// display name; load everything else (role, coins, profile...) from
  /// Firestore, MySQL or your API.
  ///
  /// Called only when there is no cached user for this uid: the first
  /// sign-in on a device, a different account signing in, or
  /// [refreshUser]. The result is cached in [dbRepo] for you, so restarts
  /// and offline launches don't call this again.
  ///
  /// If the profile doesn't exist yet (for example, sign-up hasn't created
  /// the Firestore doc), either create it here or throw. A throw surfaces
  /// through [onUserError] and is retried on the next auth change or
  /// [refreshUser].
  @override
  @protected
  @visibleForOverriding
  FutureOr<T> fetchUser(User firebaseUser);

  @override
  @protected
  bool isCachedUserFor(T cachedUser, User identity) =>
      cachedUser.firebaseUid == identity.uid;

  /// Uses [FirebaseAuth.authStateChanges]: sign-in and sign-out only.
  /// Token refreshes and profile edits don't change who is signed in.
  @override
  @protected
  Stream<User?> streamIdentity() => auth.authStateChanges();

  @override
  @protected
  User? getIdentity() => auth.currentUser;
}
