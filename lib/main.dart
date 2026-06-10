import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const FocusTelemetryApp());
}

class FocusTelemetryApp extends StatelessWidget {
  const FocusTelemetryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Focus Telemetry',
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: Colors.black,
        scaffoldBackgroundColor: const Color(0xFF121212),
        colorScheme: const ColorScheme.dark(
          primary: Colors.redAccent,
          secondary: Colors.amber,
        ),
      ),
      home: const TelemetryDashboard(),
    );
  }
}

class TelemetryDashboard extends StatefulWidget {
  const TelemetryDashboard({super.key});

  @override
  State<TelemetryDashboard> createState() => _TelemetryDashboardState();
}

class _TelemetryDashboardState extends State<TelemetryDashboard> {
  static const platform = MethodChannel('com.facetracker/control');
  bool _isServiceRunning = false;
  String _selectedSubject = 'Physics';

  final List<String> _subjects = ['Physics', 'Chemistry', 'Mathematics', 'Biology'];

  Future<void> _startNativeService() async {
    try {
      final configJson = jsonEncode({
        "subjectTag": _selectedSubject,
        "targetExam": "JEE"
      });

      final result = await platform.invokeMethod('startService', {'config': configJson});
      if (result == true) {
        setState(() {
          _isServiceRunning = true;
        });
      }
    } on PlatformException catch (e) {
      debugPrint("Failed to start service: '${e.message}'.");
    }
  }

  Future<void> _stopNativeService() async {
    try {
      final result = await platform.invokeMethod('stopService');
      if (result == true) {
        setState(() {
          _isServiceRunning = false;
        });
      }
    } on PlatformException catch (e) {
      debugPrint("Failed to stop service: '${e.message}'.");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Focus Engine Status', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.black87,
        elevation: 0,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _isServiceRunning ? Icons.check_circle_outline : Icons.camera_enhance,
              size: 100,
              color: _isServiceRunning ? Colors.greenAccent : Colors.white54,
            ),
            const SizedBox(height: 24),
            Text(
              _isServiceRunning 
                ? "Offline Telemetry Active\nLogging locally to SQLite" 
                : "Engine Dormant\nSelect subject to calibrate",
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, color: Colors.white70),
            ),
            const SizedBox(height: 48),
            if (!_isServiceRunning) ...[
              DropdownButton<String>(
                value: _selectedSubject,
                dropdownColor: Colors.black87,
                style: const TextStyle(color: Colors.white, fontSize: 18),
                items: _subjects.map((String value) {
                  return DropdownMenuItem<String>(
                    value: value,
                    child: Text(value),
                  );
                }).toList(),
                onChanged: (String? newValue) {
                  setState(() {
                    _selectedSubject = newValue!;
                  });
                },
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _startNativeService,
                icon: const Icon(Icons.play_arrow, size: 28),
                label: const Text("Start Hardware Pipeline", style: TextStyle(fontSize: 18)),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ] else ...[
              ElevatedButton.icon(
                onPressed: _stopNativeService,
                icon: const Icon(Icons.stop, size: 28),
                label: const Text("Stop Session & Compile Log", style: TextStyle(fontSize: 18)),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  backgroundColor: Colors.grey[800],
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ]
          ],
        ),
      ),
    );
  }
}
