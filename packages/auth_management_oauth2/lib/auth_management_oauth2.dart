import 'dart:async';
import 'dart:developer';
import 'dart:io' show File;

import 'package:flutter/foundation.dart' show protected, visibleForOverriding;
import 'package:http/http.dart' as http;
import 'package:oauth2/oauth2.dart' as oauth2;
import 'package:auth_management/auth_management.dart'
    show IdentityAuthRepository;
import 'package:path_provider/path_provider.dart';

/// OAuth2 as the identity provider for your app's user model [T].
///
/// An OAuth2 sign-in only gives you tokens, no user. Implement [fetchUser]
/// to call your `/me` or `/userinfo` endpoint with the authenticated
/// [oauth2.Client] and build [T]:
///
/// ```dart
/// class AuthService extends BaseOauth2AuthManagement<AppUser>
///     with AuthorizationCodeGrantMixin {
///   @override
///   Future<AppUser> fetchUser(oauth2.Client session) async {
///     final res = await session.get(Uri.parse('https://api.example.com/me'));
///     return AppUser.fromJson(jsonDecode(res.body));
///   }
///   // endpoints, identifier, secret, dbRepo...
/// }
/// ```
///
/// Credentials are stored on disk, so the session survives restarts until
/// [signOut].
abstract class BaseOauth2AuthManagement<T>
    extends IdentityAuthRepository<oauth2.Client, T> {
  /// The HTTP client for API calls: the authenticated [oauth2.Client] when
  /// signed in, a plain [http.Client] otherwise.
  http.Client client = http.Client();

  oauth2.Client? _session;
  final StreamController<oauth2.Client?> _sessionChanges =
      StreamController<oauth2.Client?>.broadcast();

  /// Restores stored credentials, then starts listening for the user.
  @override
  Future<void> initialize() async {
    final client = await getClient();
    if (client != null) {
      _setSession(client);
    }

    super.initialize();
  }

  Uri get authorizationEndpoint;

  String get identifier;

  String get secret;

  /// Loads your app's user model [T] for the signed-in [session].
  ///
  /// **You implement this.** OAuth2 gives you tokens, not a user: use
  /// [session] (an authenticated [http.Client]) to call your `/me` or
  /// `/userinfo` endpoint and build [T].
  ///
  /// Called only when there is no cached user: the first sign-in on a
  /// device or [refreshUser]. The result is cached in [dbRepo] for you.
  @override
  @protected
  @visibleForOverriding
  FutureOr<T> fetchUser(oauth2.Client session);

  @override
  @protected
  Stream<oauth2.Client?> streamIdentity() async* {
    yield _session;
    yield* _sessionChanges.stream;
  }

  @override
  @protected
  oauth2.Client? getIdentity() => _session;

  /// Deletes the stored credentials, then clears the cached user and
  /// provider state.
  @override
  Future<void> signOut() async {
    final credentialsFile = await _credentialsFile();
    if (await credentialsFile.exists()) {
      await credentialsFile.delete();
    }

    _session?.close();
    _session = null;
    client = http.Client();
    _sessionChanges.add(null);

    await super.signOut();
  }

  @protected
  Future<oauth2.Client?> getClient() async {
    final credentialsFile = await _credentialsFile();

    final exists = await credentialsFile.exists();

    if (exists) {
      log(
        'credentials file exists, creating client',
        name: '🦋 OAuth2 Auth Management',
        level: 800,
      );
      final credentials = oauth2.Credentials.fromJson(
        await credentialsFile.readAsString(),
      );
      return oauth2.Client(credentials, identifier: identifier, secret: secret);
    }

    return null;
  }

  @protected
  Future<void> storeClient(oauth2.Client client) async {
    final credentialsFile = await _credentialsFile();

    final exists = await credentialsFile.exists();

    if (!exists) {
      credentialsFile.create(recursive: true);
    }

    // Once we're done with the client, save the credentials file. This ensures
    // that if the credentials were automatically refreshed while using the
    // client, the new credentials are available for the next run of the
    // program.
    await credentialsFile.writeAsString(client.credentials.toJson());

    _setSession(client);
    _sessionChanges.add(client);
  }

  void _setSession(oauth2.Client session) {
    _session = session;
    client = session;
  }

  Future<File> _credentialsFile() async {
    final docDir = await getApplicationDocumentsDirectory();
    return File('${docDir.path}/credentials.json');
  }
}
