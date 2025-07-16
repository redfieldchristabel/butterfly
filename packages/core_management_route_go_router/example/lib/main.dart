import 'package:core_management/core_management.dart';
import 'package:flutter/material.dart';
import 'package:go_router_example/services/auth.dart';
import 'package:go_router_example/services/route.dart';
import 'package:go_router_example/services/theme.dart';

void main() {
  authService.initialize();

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late final config = routeService.routerConfig;

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Flutter Demo',
      theme: coreService.themeService.theme(context),
      routerConfig: routeService.routerConfig,
    );
  }
}

class CoreService extends BaseCoreService {
  final iTHemeService = ThemeService();

  @override
  BaseThemeService get themeService => iTHemeService;
}

final coreService = CoreService();
