import 'dart:async';

import 'package:auth_management/auth_management.dart';
import 'package:firebase_auth/firebase_auth.dart';

abstract class FirebaseAuthManagementRepository<T>
    implements AuthServiceRepository<T> {
  final FirebaseAuth auth = FirebaseAuth.instance;
  final AuthManagementDatabaseRepository<T> localDatabase;

  FirebaseAuthManagementRepository(this.localDatabase);

  /// ALso see [FirebaseAuth.signInWithEmailAndPassword]
  Future<UserCredential> signInWithEmailAndPassword(
          String email, String password) =>
      auth.signInWithEmailAndPassword(email: email, password: password);

  /// Signs out the current user from Firebase and clears
  /// the local user data.
  ///
  /// This method calls [FirebaseAuth.signOut] to sign out the user
  /// and [AuthManagementDatabaseRepository.clearUser] to clear
  /// the user data from the local database.
  @override
  Future<void> signOut() async {
    await auth.signOut();
    await localDatabase.clearUser();
  }

  /// Retrieves the current user from Firebase Authentication.
  ///
  /// This method returns the currently signed-in user, if any, transformed
  /// into a custom user type [T] using [morphUser].
  ///
  /// Also see [FirebaseAuth.currentUser].
  @override
  FutureOr<T?> getUser() {
    final User? user = auth.currentUser;
    return user != null ? morphUser(user) : null;
  }

  /// Streams the current user from Firebase Authentication.
  ///
  /// This method returns a stream which emits the currently signed-in user,
  /// if any, transformed into a custom user type [T] using [morphUser].
  ///
  /// Also see [FirebaseAuth.userChanges].
  @override
  Stream<T?> streamUser() {
    return auth
        .userChanges()
        .asyncMap((event) => event != null ? morphUser(event) : null);
  }

  /// Converts a [User] object into a custom user type [T].
  ///
  /// This method is responsible for transforming the [User] object obtained
  /// from Firebase Authentication into a user model defined by the application.
  /// The transformation should map necessary properties from the [User] to
  /// the custom user type [T].
  ///
  /// The implementation of this method should handle any specific logic required
  /// to populate the custom user type, such as mapping fields or handling
  /// additional data.
  ///
  /// Example:
  /// ```dart
  /// @override
  /// FutureOr<MyUserModel> morphUser(User user) {
  ///   return MyUserModel(
  ///     uid: user.uid,
  ///     email: user.email,
  ///     displayName: user.displayName,
  ///     // Add other fields as necessary
  ///   );
  /// }
  /// ```
  ///
  /// [user]: The Firebase [User] object to be transformed.
  Future<T> morphUser(User user) async {
    final T? localUser = await localDatabase.getUser();
    if (localUser != null) {
      return localUser;
    }

    return fetchUser();
  }

  /// Fetches user data from the remote database.
  ///
  /// This method is used to manually fetch user data from the database.
  /// It is called by the [AuthManagement] when the user data is not available
  /// from local storage.
  Future<T> fetchUser();
}
