import 'package:flutter/material.dart';

import 'home_screen.dart';

class SynchroFilmApp extends StatelessWidget {
  const SynchroFilmApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'App Synchro Film',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepOrange,
          brightness: Brightness.dark,
        ),
      ),
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepOrange),
      ),
      home: const HomeScreen(),
    );
  }
}
