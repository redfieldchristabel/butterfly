import 'package:auth_management_oauth2/auth_management_oauth2.dart';
import 'package:oauth2/oauth2.dart' as oauth2;

mixin ClientCredential on BaseOauth2AuthManagement {
  Future<void> signInWithClientCredential() async {
    final client = await oauth2.clientCredentialsGrant(
      authorizationEndpoint,
      identifier,
      secret,
    );

    storeClient(client);
  }
}
