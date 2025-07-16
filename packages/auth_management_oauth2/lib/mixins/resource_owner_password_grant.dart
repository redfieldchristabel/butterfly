import 'package:auth_management_oauth2/auth_management_oauth2.dart';
import 'package:oauth2/oauth2.dart' as oauth2;

mixin ResourceOwnerPasswordGrant on BaseOauth2AuthManagement {
  Future<void> signInWithPassword({
    required String username,
    required String password,
  }) async {
    // Make a request to the authorization endpoint that will produce the fully
    // authenticated Client.
    final client = await oauth2.resourceOwnerPasswordGrant(
      authorizationEndpoint,
      username,
      password,
      identifier: identifier,
      secret: secret,
    );

    storeClient(client);
  }
}
