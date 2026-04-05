import 'package:flutter/material.dart';

import 'src/ui/screens/home_screen.dart';

void main() {
  runApp(const SinkerApp());
}

class SinkerApp extends StatelessWidget {
  const SinkerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sinker',
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
      ),
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
