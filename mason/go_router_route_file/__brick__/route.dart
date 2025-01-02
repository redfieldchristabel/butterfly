import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

part 'route.g.dart';

@TypedGoRoute<HomeRoute>(path: '/')
class HomeRoute extends GoRouteData {
  @override
  Widget build(BuildContext context, GoRouterState state) {
    return Scaffold(
      body: Center(child: Text("Hello World")),
    );
  }
}

//this is example for second route
@TypedGoRoute<SecondRoute>(path: '/second')
class SecondRoute extends GoRouteData {
  @override
  Widget build(BuildContext context, GoRouterState state) {
    return Scaffold(
      body: Center(child: Text("This is second route")),
    );
  }
}