import 'package:core_management_route_go_router/go_router_auth_route.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:go_router_example/route.dart';
import 'package:go_router_example/services/auth.dart';

import '../models/user.dart';

class RouteService extends GoRouterAuthRoute<User> {
  @override
  List<String> get authTriggerRoutes => [signInRoute];

  @override
  List<RouteBase> get routes => $appRoutes;

  @override
  User? get user => authService.currentUser;

  @override
  // TODO: implement refreshListenable
  Listenable? get refreshListenable => authService;
}

final routeService = RouteService();
