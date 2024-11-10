import 'package:auth_management_firebase/auth_management_firebase.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'package:auth_management_firebase/auth_management_firebase_google.dart';

/// A mixin that provides Google Sign-In functionality for Firebase authentication.
///
/// Note: This mixin is intended for use with native applications (Android & iOS).
/// For non-native platforms, please use the mixin from the [SignInWithGoogleWebMixin] library.
mixin SignInWithGoogleFirebase on FirebaseAuthManagementRepository {
  /// Signs in the user with Google and returns a [UserCredential].
  ///
  /// This method triggers the Google authentication flow and returns the
  /// [UserCredential] upon successful sign-in.
  Future<UserCredential> signInWithGoogle() async {
    // Trigger the authentication flow
    final GoogleSignInAccount? googleUser = await GoogleSignIn().signIn();

    // Obtain the auth details from the request
    final GoogleSignInAuthentication? googleAuth =
        await googleUser?.authentication;

    // Create a new credential
    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth?.accessToken,
      idToken: googleAuth?.idToken,
    );

    // Once signed in, return the UserCredential
    return await FirebaseAuth.instance.signInWithCredential(credential);
  }
}
