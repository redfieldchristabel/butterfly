import 'dart:developer';
import 'dart:io' show File;

import 'package:flutter/foundation.dart' show protected;
import 'package:http/http.dart' as http;
import 'package:oauth2/oauth2.dart' as oauth2;
import 'package:auth_management/auth_management.dart'
    show AuthServiceRepository;
import 'package:path_provider/path_provider.dart';

abstract class BaseOauth2AuthManagement extends AuthServiceRepository {
  http.Client client = http.Client();

  @override
  Future<void> initialize() async {
    final client = await getClient();
    if (client != null) {
      this.client = client;
    }

    super.initialize();
  }

  Uri get authorizationEndpoint;

  String get identifier;

  String get secret;

  @protected
  Future<oauth2.Client?> getClient() async {
    final docDir = await getApplicationDocumentsDirectory();

    final credentialsFile = File('${docDir.path}/credentials.json');

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
    final docDir = await getApplicationDocumentsDirectory();

    final credentialsFile = File('${docDir.path}/credentials.json');

    final exists = await credentialsFile.exists();

    if (!exists) {
      credentialsFile.create(recursive: true);
    }

    // Once we're done with the client, save the credentials file. This ensures
    // that if the credentials were automatically refreshed while using the
    // client, the new credentials are available for the next run of the
    // program.
    await credentialsFile.writeAsString(client.credentials.toJson());

    this.client = client;
  }
}
