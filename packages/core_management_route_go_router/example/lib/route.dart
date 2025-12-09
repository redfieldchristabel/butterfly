import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:go_router_example/screens/home.dart';
import 'package:go_router_example/screens/second.dart';
import 'package:go_router_example/services/auth.dart';

part 'route.g.dart';

@TypedGoRoute<HomeRoute>(path: '/')
class HomeRoute extends GoRouteData with _$HomeRoute {
  @override
  Widget build(BuildContext context, GoRouterState state) {
    return HomeScreen();
  }
}

//this is example for second route
@TypedGoRoute<SecondRoute>(path: '/second')
class SecondRoute extends GoRouteData with _$SecondRoute {
  @override
  Widget build(BuildContext context, GoRouterState state) {
    return SecondScreen();
  }
}

@TypedGoRoute<LoginRoute>(path: '/login')
class LoginRoute extends GoRouteData with _$LoginRoute {
  @override
  Widget build(BuildContext context, GoRouterState state) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          authService.signIn();
        },
        label: Text('Login'),
        icon: Icon(Icons.login),
      ),
    );
  }
}
