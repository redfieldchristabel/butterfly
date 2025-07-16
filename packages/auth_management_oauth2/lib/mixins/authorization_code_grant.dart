import 'package:app_links/app_links.dart' show AppLinks;
import 'package:auth_management_oauth2/auth_management_oauth2.dart';
import 'package:oauth2/oauth2.dart' as oauth2;
import 'package:url_launcher/url_launcher.dart';

mixin AuthorizationCodeGrantMixin on BaseOauth2AuthManagement {
  Uri get tokenEndpoint;

  // This is a URL on your application's server. The authorization server
  // will redirect the resource owner here once they've authorized the
  // client. The redirection will include the authorization code in the
  // query parameters.
  Uri get redirectUrl;

  Future<void> signInWithAuthorizationCode() async {
    // If we don't have OAuth2 credentials yet, we need to get the resource owner
    // to authorize us. We're assuming here that we're a command-line application.
    final grant = oauth2.AuthorizationCodeGrant(
      identifier,
      authorizationEndpoint,
      tokenEndpoint,
      secret: secret,
    );

    // A URL on the authorization server (authorizationEndpoint with some additional
    // query parameters). Scopes and state can optionally be passed into this method.
    var authorizationUrl = grant.getAuthorizationUrl(redirectUrl);

    // Redirect the resource owner to the authorization URL. Once the resource
    // owner has authorized, they'll be redirected to `redirectUrl` with an
    // authorization code. The `redirect` should cause the browser to redirect to
    // another URL which should also have a listener.
    //
    // `redirect` and `listen` are not shown implemented here. See below for the
    // details.
    final responseUrl = await redirect(authorizationUrl);

    final client = await grant.handleAuthorizationResponse(
      responseUrl.queryParameters,
    );

    storeClient(client);

  }

  Future<Uri> redirect(Uri authorizationUrl) async {
    final appLinks = AppLinks(); // AppLinks is singleton
    final canLaunch = await canLaunchUrl(authorizationUrl);
    if (canLaunch) {
      await launchUrl(authorizationUrl);
    }

    int count = 0;
    Uri? responseUrl;

    await for (final url in appLinks.stringLinkStream) {
      count++;
      if (url.startsWith(redirectUrl.toString())) {
        responseUrl = Uri.parse(url);
        break;
      }
      if (count > 10) {
        responseUrl = null;
        break;
      }
    }

    if (responseUrl == null) {
      throw Exception('No response url after 10 attempts');
    }

    return responseUrl;
  }
}
