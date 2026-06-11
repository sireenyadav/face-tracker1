import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../telemetry/webrtc_stream_handler.dart';

const Color emeraldColor = Color(0xFF10B981);

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> with SingleTickerProviderStateMixin {
  // Define the method channel matching the native Kotlin pipeline hooks
  static const platform = MethodChannel('com.facetracker/control');
  static const telemetryStream = EventChannel('com.facetracker/telemetryStream');
  static const syncStream = EventChannel('com.facetracker/syncStream');

  StreamSubscription? _telemetrySubscription;
  StreamSubscription? _syncSubscription;
  
  int _liveScore = 100;
  String _liveState = "Initializing...";
  String _syncStatus = "Awaiting Sync...";
  bool _isLiveStreaming = false;

  bool _isSessionActive = false;
  int _elapsedSeconds = 0;
  Timer? _timer;

  bool _isDbConnected = false;
  String _selectedSubject = 'Physics';
  String _activityType = 'Lecture';
  String _chapterName = '';
  int _lectureNumber = 1;
  final TextEditingController _chapterController = TextEditingController();
  final TextEditingController _lectureController = TextEditingController(text: '1');
  
  // Animation controller for the pulsing focus effect when active
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _checkSupabaseConnection();
    
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.03).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Setup MethodChannel listener for incoming video requests from native Android layer
    platform.setMethodCallHandler(_handleNativeMethodCall);
  }

  void _checkSupabaseConnection() async {
    try {
      await Supabase.instance.client.from('focus_sessions').select('id').limit(1);
      if (mounted) setState(() { _isDbConnected = true; });
    } catch (e) {
      if (mounted) setState(() { _isDbConnected = false; });
    }
  }

  Future<dynamic> _handleNativeMethodCall(MethodCall call) async {
    if (call.method == "onVideoRequest") {
      // The native 5-second polling loop caught a video_request == true flag
      _triggerVideoAmbushOverlay();
    }
  }

  void _triggerVideoAmbushOverlay() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const VideoAmbushScreen(),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  void dispose() {
    _chapterController.dispose();
    _lectureController.dispose();
    _telemetrySubscription?.cancel();
    _syncSubscription?.cancel();
    _timer?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  Future<bool> _requestPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.camera,
      Permission.notification,
    ].request();
    return statuses[Permission.camera]!.isGranted && statuses[Permission.notification]!.isGranted;
  }

  void _toggleSession() async {
    if (_isSessionActive) {
      // ---------------------------------------------------------
      // SURRENDER / STOP SESSION LOGIC
      // ---------------------------------------------------------
      _telemetrySubscription?.cancel();
      _syncSubscription?.cancel();
      _timer?.cancel();
      _pulseController.stop();
      _pulseController.reset();
      
      try {
        await platform.invokeMethod('stopService');
      } on PlatformException catch (e) {
        debugPrint("Failed to stop session: '${e.message}'.");
      }
      
      setState(() {
        _isSessionActive = false;
      });
    } else {
      // ---------------------------------------------------------
      // START FOCUS SESSION LOGIC
      // ---------------------------------------------------------
      if (!await _requestPermissions()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Camera & Notification permissions are strictly required.")));
        }
        return;
      }

      setState(() {
        _elapsedSeconds = 0;
        _liveScore = 100;
        _liveState = "Initializing...";
        _syncStatus = "Awaiting Sync...";
        _isSessionActive = true;
      });
      
      _pulseController.repeat(reverse: true);
      
      try {
        final sessionId = const Uuid().v4();
        final configJson = jsonEncode({
          "sessionId": sessionId,
          "subjectTag": _selectedSubject,
          "targetExam": "JEE",
          "activityType": _activityType,
          "chapterName": _chapterName,
          "lectureNumber": _activityType == 'Lecture' ? _lectureNumber : 0
        });
        await platform.invokeMethod('startService', {'config': configJson});

        _telemetrySubscription = telemetryStream.receiveBroadcastStream().listen((event) {
          final data = Map<String, dynamic>.from(event);
          if (mounted) {
            setState(() {
              _liveScore = data['score'] ?? 100;
              _liveState = data['state'] ?? "Unknown";
            });
          }
        });
        
        _syncSubscription = syncStream.receiveBroadcastStream().listen((event) {
          final data = Map<String, dynamic>.from(event);
          if (mounted) {
            setState(() {
              _isLiveStreaming = data['isLive'] ?? false;
              int syncedCount = data['syncedRecords'] ?? 0;
              final now = DateTime.now();
              _syncStatus = "Synced $syncedCount rows at ${now.hour}:${now.minute.toString().padLeft(2, '0')}";
            });
          }
        });
      } on PlatformException catch (e) {
        debugPrint("Failed to start session: '${e.message}'.");
      }
      
      // Fire UI standard Dart timer running at exactly 1-second intervals
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        setState(() {
          _elapsedSeconds++;
        });
      });
    }
  }

  String _formatElapsedTime(int seconds) {
    int h = seconds ~/ 3600;
    int m = ((seconds % 3600) ~/ 60);
    int s = seconds % 60;
    
    String hours = h.toString().padLeft(2, '0');
    String minutes = m.toString().padLeft(2, '0');
    String secs = s.toString().padLeft(2, '0');
    
    return "$hours:$minutes:$secs";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A), // Tailwind slate-900 equivalent
      appBar: AppBar(
        title: const Text('Focus Control Hub', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF1E293B), // Tailwind slate-800
        elevation: 0,
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 12,
                  color: _isDbConnected ? emeraldColor : Colors.redAccent,
                ),
                const SizedBox(width: 8),
                Text(
                  _isDbConnected ? "DB Connected" : "DB Offline",
                  style: TextStyle(
                    color: _isDbConnected ? emeraldColor : Colors.redAccent,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          )
        ],
      ),
      bottomSheet: _isSessionActive ? Container(
        color: _isLiveStreaming ? Colors.redAccent.withValues(alpha: 0.1) : const Color(0xFF1E293B),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _isLiveStreaming ? Icons.wifi_tethering : Icons.cloud_sync,
              size: 16,
              color: _isLiveStreaming ? Colors.redAccent : emeraldColor,
            ),
            const SizedBox(width: 8),
            Text(
              _isLiveStreaming ? "🔴 LIVE STREAMING TO PARENT" : _syncStatus,
              style: TextStyle(
                color: _isLiveStreaming ? Colors.redAccent : emeraldColor,
                fontWeight: FontWeight.bold,
                fontSize: 12,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      ) : null,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ========================================================
                // THE VISUAL STOPWATCH
                // ========================================================
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: _isSessionActive ? emeraldColor : const Color(0xFF334155),
                      width: 2,
                    ),
                    boxShadow: _isSessionActive ? [
                      BoxShadow(
                        color: emeraldColor.withValues(alpha: 0.15),
                        blurRadius: 20,
                        spreadRadius: 2,
                      )
                    ] : [],
                  ),
                  child: Column(
                    children: [
                      const Text(
                        "ELAPSED TIME",
                        style: TextStyle(
                          color: Color(0xFF94A3B8), // slate-400
                          fontSize: 14,
                          letterSpacing: 2,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _formatElapsedTime(_elapsedSeconds),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 64,
                          fontFamily: 'monospace', // Standard mono formatting for clocks
                          fontWeight: FontWeight.w300,
                          letterSpacing: -2,
                        ),
                      ),
                      if (_isSessionActive) ...[
                        const SizedBox(height: 16),
                        Text(
                          "$_liveScore%",
                          style: TextStyle(
                            fontSize: 48,
                            fontWeight: FontWeight.bold,
                            color: _liveScore >= 75 ? emeraldColor : Colors.redAccent,
                          ),
                        ),
                        Text(
                          _liveState,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                
                const SizedBox(height: 32),
                
                // ========================================================
                // THE ADVANCED CONTEXT FORM
                // ========================================================
                const Text("ACTIVITY TYPE", style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12, letterSpacing: 1.5, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: ['Lecture', 'Revision', 'DPP', 'PYQ', 'Mock'].map((type) {
                      final isSelected = _activityType == type;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8.0),
                        child: ChoiceChip(
                          label: Text(type),
                          selected: isSelected,
                          selectedColor: emeraldColor.withValues(alpha: 0.2),
                          backgroundColor: const Color(0xFF1E293B),
                          labelStyle: TextStyle(color: isSelected ? emeraldColor : Colors.white70, fontWeight: FontWeight.bold),
                          onSelected: _isSessionActive ? null : (selected) {
                            if (selected) setState(() => _activityType = type);
                          },
                        ),
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 24),
                
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text("TARGET SUBJECT", style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12, letterSpacing: 1.5, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 8),
                          DropdownButtonFormField<String>(
                            initialValue: _selectedSubject,
                            dropdownColor: const Color(0xFF1E293B),
                            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
                            decoration: InputDecoration(
                              filled: true,
                              fillColor: const Color(0xFF1E293B),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                            ),
                            items: ['Physics', 'Chemistry', 'Maths'].map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
                            onChanged: _isSessionActive ? null : (val) => setState(() => _selectedSubject = val!),
                          ),
                        ],
                      ),
                    ),
                    if (_activityType == 'Lecture') ...[
                      const SizedBox(width: 16),
                      Expanded(
                        flex: 1,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text("LEC #", style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12, letterSpacing: 1.5, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 8),
                            TextField(
                              controller: _lectureController,
                              keyboardType: TextInputType.number,
                              enabled: !_isSessionActive,
                              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
                              decoration: InputDecoration(
                                filled: true,
                                fillColor: const Color(0xFF1E293B),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                              ),
                              onChanged: (val) => _lectureNumber = int.tryParse(val) ?? 1,
                            ),
                          ],
                        ),
                      ),
                    ]
                  ],
                ),
                const SizedBox(height: 24),

                const Text("CHAPTER CONTEXT", style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12, letterSpacing: 1.5, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                TextField(
                  controller: _chapterController,
                  enabled: !_isSessionActive,
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
                  decoration: InputDecoration(
                    hintText: "e.g. Rotational Mechanics",
                    hintStyle: const TextStyle(color: Colors.white30),
                    filled: true,
                    fillColor: const Color(0xFF1E293B),
                    prefixIcon: const Icon(Icons.book_rounded, color: emeraldColor),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                  ),
                  onChanged: (val) => _chapterName = val,
                ),

                const SizedBox(height: 48),
                
                // ========================================================
                // THE CONTROL ACTION BUTTON
                // ========================================================
                AnimatedBuilder(
                  animation: _pulseAnimation,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: _isSessionActive ? _pulseAnimation.value : 1.0,
                      child: child,
                    );
                  },
                  child: ElevatedButton(
                    onPressed: _toggleSession,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isSessionActive ? Colors.redAccent : emeraldColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      elevation: _isSessionActive ? 8 : 4,
                      shadowColor: _isSessionActive ? Colors.red.withValues(alpha: 0.4) : emeraldColor.withValues(alpha: 0.4),
                    ),
                    child: Text(
                      _isSessionActive ? "SURRENDER / STOP SESSION" : "START FOCUS SESSION",
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ==============================================================================
// THE 3-SECOND AMBUSH VIDEO OVERLAY
// ==============================================================================

class VideoAmbushScreen extends StatefulWidget {
  const VideoAmbushScreen({super.key});

  @override
  State<VideoAmbushScreen> createState() => _VideoAmbushScreenState();
}

class _VideoAmbushScreenState extends State<VideoAmbushScreen> {
  int _countdown = 3;
  Timer? _countdownTimer;
  bool _initializingVideo = false;
  
  // WebRTC Pipeline execution hook
  late WebRTCStreamHandler _webrtcHandler;

  @override
  void initState() {
    super.initState();
    
    // In production, grab the real session ID from state. Mocking for now.
    _webrtcHandler = WebRTCStreamHandler(sessionId: '11111111-1111-1111-1111-111111111111');
    _startCountdown();
  }

  void _startCountdown() {
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_countdown > 1) {
        setState(() {
          _countdown--;
        });
      } else {
        setState(() {
          _countdown = 0;
          _initializingVideo = true;
        });
        timer.cancel();
        // The exact millisecond the countdown hits 0, execute the WebRTC hookup
        _initializeWebRTCPeerConnection();
      }
    });
  }

  Future<void> _initializeWebRTCPeerConnection() async {
    debugPrint("EXECUTING: initializeWebRTCPeerConnection(). Binding streams...");
    await _webrtcHandler.initialize();
    
    // Force a re-build to guarantee the RTCVideoView binds correctly
    setState(() {});
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _webrtcHandler.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // PopScope hard-locks the screen so the user cannot dismiss the ambush
    return PopScope(
      canPop: false, 
      child: Scaffold(
        backgroundColor: Colors.black, // Immersive black overlay
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.videocam_rounded,
                color: Colors.redAccent,
                size: 80,
              ),
              const SizedBox(height: 32),
              const Text(
                "PARENTAL AUDIT TRIGGERED",
                style: TextStyle(
                  color: Colors.redAccent,
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 48),
              if (!_initializingVideo) ...[
                Text(
                  "Live Verification Starting in: $_countdown Seconds",
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 18,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  "$_countdown",
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 140,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ] else ...[
                const CircularProgressIndicator(color: emeraldColor, strokeWidth: 4),
                const SizedBox(height: 32),
                const Text(
                  "TRANSMITTING SECURE STREAM...",
                  style: TextStyle(
                    color: emeraldColor,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 48),
                // Tiny preview indicator showing streaming is actively live
                Container(
                  width: 120,
                  height: 160,
                  decoration: BoxDecoration(
                    color: Colors.grey[900],
                    border: Border.all(color: emeraldColor, width: 2),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: emeraldColor.withValues(alpha: 0.3),
                        blurRadius: 10,
                        spreadRadius: 2,
                      )
                    ]
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Stack(
                      children: [
                        RTCVideoView(
                          _webrtcHandler.localRenderer,
                          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                          mirror: true,
                        ),
                        Positioned(
                          top: 4,
                          right: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.6),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              "LIVE",
                              style: TextStyle(color: Colors.redAccent, fontSize: 10, fontWeight: FontWeight.bold),
                            ),
                          ),
                        )
                      ],
                    ),
                  ),
                ),
              ]
            ],
          ),
        ),
      ),
    );
  }
}
