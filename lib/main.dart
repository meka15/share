import 'package:flutter/material.dart';
import 'core/services/discovery_service.dart';
import 'core/services/file_transfer_service.dart';
import 'ui/screens/home_screen.dart';

// Dependency container (Static for simplicity)
class AppConfig {
  static final discoveryService = DiscoveryService();
  static final transferService = FileTransferService();
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AntigravityShareApp());
}

class AntigravityShareApp extends StatelessWidget {
  const AntigravityShareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Antigravity Share',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blueAccent,
          brightness: Brightness.dark,
        ),
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
