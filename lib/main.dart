import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/services.dart';
import 'screens/main_screen.dart';
import 'screens/video_ambush_screen.dart';
import 'theme/app_theme.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

const String currentClientVersion = '1.0.0';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize Supabase with the provided Project URL and Anon Key
  await Supabase.initialize(
    url: 'https://crmjzxhlggfpisknbjrr.supabase.co',
    publishableKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNybWp6eGhsZ2dmcGlza25ianJyIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc4MTE3MjMxOCwiZXhwIjoyMDk2NzQ4MzE4fQ.8CoDj9TVVuScYfTEvrF8kc99E5JpNOXGF-NJVj6SvQ8',
  );

  // API Handshake / Version Check
  bool requireUpdate = false;
  try {
    final response = await Supabase.instance.client.rpc('get_system_status');
    final String minVersion = response['min_supported_client_version'];
    
    // Simple lexicographical comparison for version strings (e.g. '1.0.1' > '1.0.0')
    if (minVersion.compareTo(currentClientVersion) > 0) {
      requireUpdate = true;
    }
  } catch (e) {
    debugPrint("System status handshake failed: $e");
  }

  runApp(
    ChangeNotifierProvider(
      create: (_) => ThemeProvider(),
      child: requireUpdate ? const UpdateRequiredApp() : const FocusTelemetryApp(),
    ),
  );
}

class UpdateRequiredApp extends StatelessWidget {
  const UpdateRequiredApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Update Required',
      theme: AppTheme.darkTheme,
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.update_rounded, size: 80, color: Colors.redAccent),
              const SizedBox(height: 24),
              const Text(
                'CRITICAL UPDATE REQUIRED',
                style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 32.0),
                child: Text(
                  'Your tracking client is outdated and cannot sync data securely with the servers. Please update the application to continue.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 16),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class FocusTelemetryApp extends StatefulWidget {
  const FocusTelemetryApp({super.key});

  @override
  State<FocusTelemetryApp> createState() => _FocusTelemetryAppState();
}

class _FocusTelemetryAppState extends State<FocusTelemetryApp> {
  static const platform = MethodChannel('com.facetracker/control');

  @override
  void initState() {
    super.initState();
    
    // Handle foreground intents (onNewIntent)
    platform.setMethodCallHandler((call) async {
      if (call.method == 'route' && call.arguments == 'video_ambush') {
        final res = await Supabase.instance.client.from('focus_sessions').select('id').eq('status', 'active').order('started_at', ascending: false).limit(1);
        if (res.isNotEmpty) {
          navigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => VideoAmbushScreen(sessionId: res.first['id'])));
        }
      }
    });

    // Handle cold boot intents (onCreate cache)
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final String? initialRoute = await platform.invokeMethod('getInitialRoute');
        if (initialRoute == 'video_ambush') {
          final res = await Supabase.instance.client.from('focus_sessions').select('id').eq('status', 'active').order('started_at', ascending: false).limit(1);
          if (res.isNotEmpty) {
            navigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => VideoAmbushScreen(sessionId: res.first['id'])));
          }
        }
      } catch (e) {
        debugPrint("Error fetching initial route: $e");
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);

    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Focus Control Hub',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeProvider.isDarkMode ? ThemeMode.dark : ThemeMode.light,
      home: const MainScreen(),
    );
  }
}
