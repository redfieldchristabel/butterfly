import 'package:flutter/cupertino.dart';

import '../services/base_route.dart' show BaseRouteService;

mixin RouteServiceMixin {
  BaseRouteService get routeService;

  RouterConfig get routerConfig => routeService.routerConfig;
}
