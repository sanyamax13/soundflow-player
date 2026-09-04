import 'package:flutter/material.dart';
import 'app/shell.dart';
import 'core/theme.dart';

void main() {
  runApp(const SoundFlowApp());
}

class SoundFlowApp extends StatelessWidget {
  const SoundFlowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SoundFlow',
      debugShowCheckedModeBanner: false,
      theme: Afisha.theme(),
      home: const Shell(),
    );
  }
}
