import 'package:firebase_auth/firebase_auth.dart';

mixin SignInWithGoogleWebMixin {
  List<String> get scopes =>
      ['https://www.googleapis.com/auth/contacts.readonly'];

  Map<String, String> get customParameters => {
        'login_hint': 'user@example.com',
      };

  GoogleAuthProvider _makeProvider() {
    GoogleAuthProvider googleProvider = GoogleAuthProvider();

    for (final scope in scopes) {
      googleProvider.addScope(scope);
    }

    googleProvider.setCustomParameters(customParameters);
    return googleProvider;
  }

  Future<UserCredential> signInWithGoogle() async {
    // Create a new provider
    GoogleAuthProvider googleProvider = _makeProvider();

    // Once signed in, return the UserCredential
    return await FirebaseAuth.instance.signInWithPopup(googleProvider);
  }

  Future<void> signInWithGoogleRedirect() async {
    // Create a new provider
    GoogleAuthProvider googleProvider = _makeProvider();

    // Or use signInWithRedirect
    return await FirebaseAuth.instance.signInWithRedirect(googleProvider);
  }
}
