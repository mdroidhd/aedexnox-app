import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'services/cache_service.dart';
import 'services/session_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await CacheService.init();
  await SessionService.init();
  runApp(const AedexApp());
}

class AedexApp extends StatelessWidget {
  const AedexApp({super.key});

  @override
  Widget build(BuildContext context) {
    const pink = Color(0xFFFF3563);
    return MaterialApp(
      title: 'Aedexnox',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: pink,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0B0B12),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0B0B12),
          elevation: 0,
          centerTitle: false,
        ),
        cardColor: const Color(0xFF151520),
        listTileTheme: const ListTileThemeData(
          iconColor: Colors.white70,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
