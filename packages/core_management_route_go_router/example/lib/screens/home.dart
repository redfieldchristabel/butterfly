import 'package:flutter/material.dart';
import 'package:go_router_example/services/auth.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          authService.signOut();
        },
      ),
      body: const Placeholder(child: Text('Home Screen')),
    );
  }
}
