import 'package:flutter/material.dart';

void main() => runApp(const ExampleApp());

final class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: Scaffold(
      body: Center(child: Text('yl_player Android Media3 backend')),
    ),
  );
}
