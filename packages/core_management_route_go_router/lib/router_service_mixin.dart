import 'package:core_management/core_management.dart';
import 'package:core_management/mixins/router_service.dart';
import 'package:core_management_route_go_router/core_management_route_go_router.dart';
import 'package:go_router/go_router.dart' show GoRouter;

mixin GoRouterServiceMixin on BaseCoreService implements RouteServiceMixin {
  @override
  GoRouterService get routeService;

  @override
  GoRouter get routerConfig => routeService.routerConfig;
}
