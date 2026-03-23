import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
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
  // Ensure the app doesn't hang/fail on startup due to font fetching issues
  GoogleFonts.config.allowRuntimeFetching = false;
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
