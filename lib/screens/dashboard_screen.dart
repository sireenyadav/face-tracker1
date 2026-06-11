import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../theme/app_theme.dart';
import '../components/glass_container.dart';
import '../components/animated_toggle_chip.dart';
import '../components/premium_text_field.dart';
import '../components/animated_mesh_background.dart';
import '../components/study_timeline_card.dart';
import 'video_ambush_screen.dart';

const Color emeraldColor = Color(0xFF10B981);

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> with TickerProviderStateMixin {
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
  String _currentSessionId = "";

  bool _isDbConnected = false;
  String _selectedSubject = 'Physics';
  String _activityType = 'Lecture';
  String _chapterName = '';
  int _lectureNumber = 1;
  final TextEditingController _chapterController = TextEditingController();
  final TextEditingController _lectureController = TextEditingController(text: '1');
  
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  
  int _bottomNavIndex = 0;
  List<Map<String, dynamic>> _sessionHistory = [];
  bool _isLoadingHistory = true;

  @override
  void initState() {
    super.initState();
    _checkSupabaseConnection();
    _fetchSessionHistory();
    
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.02).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOutSine),
    );
  }

  void _checkSupabaseConnection() async {
    try {
      await Supabase.instance.client.from('focus_sessions').select('id').limit(1);
      if (mounted) setState(() { _isDbConnected = true; });
    } catch (e) {
      if (mounted) setState(() { _isDbConnected = false; });
    }
  }

  Future<void> _fetchSessionHistory() async {
    try {
      final data = await Supabase.instance.client
          .from('focus_sessions')
          .select()
          .order('started_at', ascending: false)
          .limit(10);
      
      if (mounted) {
        setState(() {
          _sessionHistory = List<Map<String, dynamic>>.from(data);
          _isLoadingHistory = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingHistory = false);
    }
  }

  void _listenForVideoRequests(String sessionId) {
    Supabase.instance.client.channel('signaling_trigger_$sessionId').onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'webrtc_signaling',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'session_id',
        value: sessionId,
      ),
      callback: (payload) {
        if (payload.newRecord['type'] == 'offer_parent') {
          _triggerVideoAmbushOverlay(sessionId);
        }
      }
    ).subscribe();
  }

  void _triggerVideoAmbushOverlay(String sessionId) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        pageBuilder: (context, animation, secondaryAnimation) => VideoAmbushScreen(sessionId: sessionId),
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
      _telemetrySubscription?.cancel();
      _syncSubscription?.cancel();
      _timer?.cancel();
      _pulseController.stop();
      _pulseController.reset();
      
      try {
        Supabase.instance.client.removeChannel(Supabase.instance.client.channel('signaling_trigger_$_currentSessionId'));
        // Update session as completed
        await Supabase.instance.client.from('focus_sessions').update({
          'status': 'completed',
          'ended_at': DateTime.now().toUtc().toIso8601String(),
        }).eq('id', _currentSessionId);
      } catch (_) {}
      
      try {
        await platform.invokeMethod('stopService');
      } catch (e) {
        debugPrint("Failed to stop session");
      }
      
      setState(() {
        _isSessionActive = false;
      });
      _fetchSessionHistory(); // Refresh history
    } else {
      if (!await _requestPermissions()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Camera permissions required.")));
        }
        return;
      }

      final newSessionId = const Uuid().v4();
      setState(() {
        _elapsedSeconds = 0;
        _liveScore = 100;
        _liveState = "Initializing...";
        _syncStatus = "Awaiting Sync...";
        _isSessionActive = true;
        _currentSessionId = newSessionId;
      });
      
      try {
        await Supabase.instance.client.from('focus_sessions').insert({
          'id': newSessionId,
          'user_id': Supabase.instance.client.auth.currentUser?.id ?? '00000000-0000-0000-0000-000000000000',
          'subject_tag': _selectedSubject,
          'target_exam': 'JEE',
          'activity_type': _activityType,
          'chapter_name': _chapterName,
          'lecture_number': _activityType == 'Lecture' ? _lectureNumber : 0,
          'status': 'active',
          'started_at': DateTime.now().toUtc().toIso8601String(),
        });
      } catch (e) {
        debugPrint("Failed to insert session");
      }
      
      _pulseController.repeat(reverse: true);
      
      try {
        final configJson = jsonEncode({
          "sessionId": _currentSessionId,
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
            });
          }
        });
      } catch (e) {
        debugPrint("Failed to start session");
      }
      
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        setState(() {
          _elapsedSeconds++;
        });
      });
        
      _listenForVideoRequests(_currentSessionId);
      _fetchSessionHistory(); // Refresh to show "Active Now"
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
    return AnimatedMeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent, // Background handled by Mesh
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isLandscape = constraints.maxWidth > constraints.maxHeight;
              
              if (isLandscape) {
                return _buildLandscapeLayout(context);
              } else {
                return _buildPortraitLayout(context);
              }
            },
          ),
        ),
      ),
    );
  }

  Widget _buildLandscapeLayout(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: GlassContainer(
        padding: const EdgeInsets.all(0),
        blur: 30,
        opacity: 0.15,
        child: Row(
          children: [
            Expanded(
              flex: 6,
              child: _buildControlHub(context),
            ),
            Container(
              width: 1,
              color: Theme.of(context).brightness == Brightness.dark 
                  ? Colors.white10 
                  : Colors.black12,
            ),
            Expanded(
              flex: 4,
              child: _buildStudyTimeline(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPortraitLayout(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: GlassContainer(
        padding: const EdgeInsets.all(0),
        blur: 30,
        opacity: 0.15,
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            children: [
              _buildControlHub(context),
              Container(
                height: 1,
                color: Theme.of(context).brightness == Brightness.dark 
                    ? Colors.white10 
                    : Colors.black12,
              ),
              SizedBox(
                height: 500, // Fixed height for timeline in portrait
                child: _buildStudyTimeline(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControlHub(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? Colors.white : Colors.black87;
    final secondaryColor = isDark ? Colors.white54 : Colors.black54;

    return Column(
      children: [
        // HEADER
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 32, 32, 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "Focus Control Hub",
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  color: primaryColor,
                  letterSpacing: -0.5,
                ),
              ),
              Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.notifications_none, color: secondaryColor, size: 20),
                    onPressed: () {},
                  ),
                  IconButton(
                    icon: Icon(isDark ? Icons.light_mode : Icons.dark_mode_outlined, color: secondaryColor, size: 20),
                    onPressed: () => themeProvider.toggleTheme(),
                  ),
                  Icon(Icons.battery_full, color: secondaryColor, size: 20),
                ],
              )
            ],
          ),
        ),

        // MAIN CONTENT
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 32.0, vertical: 8.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // STOPWATCH CARD
                AnimatedBuilder(
                  animation: _pulseAnimation,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: _isSessionActive ? _pulseAnimation.value : 1.0,
                      child: child,
                    );
                  },
                  child: GlassContainer(
                    blur: 20,
                    opacity: isDark ? 0.05 : 0.4,
                    padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
                    child: Column(
                      children: [
                        Text(
                          "ELAPSED TIME",
                          style: TextStyle(
                            color: secondaryColor,
                            fontSize: 10,
                            letterSpacing: 2,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 12),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          child: Text(
                            _formatElapsedTime(_elapsedSeconds),
                            key: ValueKey(_elapsedSeconds),
                            style: GoogleFonts.playfairDisplay(
                              color: primaryColor,
                              fontSize: 64,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 2,
                            ),
                          ),
                        ),
                        
                        AnimatedSize(
                          duration: const Duration(milliseconds: 400),
                          curve: Curves.easeOutExpo,
                          child: _isSessionActive ? Column(
                            children: [
                              const SizedBox(height: 20),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    "$_liveScore",
                                    style: GoogleFonts.playfairDisplay(
                                      fontSize: 42,
                                      fontWeight: FontWeight.w600,
                                      color: _liveScore >= 75 ? emeraldColor : Colors.redAccent,
                                    ),
                                  ),
                                  Text(
                                    " %",
                                    style: TextStyle(
                                      fontSize: 20,
                                      color: _liveScore >= 75 ? emeraldColor.withValues(alpha: 0.7) : Colors.redAccent.withValues(alpha: 0.7),
                                    ),
                                  ),
                                ],
                              ),
                              Text(
                                _liveState.toUpperCase(),
                                style: TextStyle(
                                  color: secondaryColor,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.5,
                                ),
                              )
                            ],
                          ) : const SizedBox.shrink(),
                        )
                      ],
                    ),
                  ),
                ),
                
                const SizedBox(height: 32),
                
                // ACTIVITY TYPE
                Text("ACTIVITY TYPE", style: TextStyle(color: secondaryColor, fontSize: 10, letterSpacing: 1.5, fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  child: Row(
                    children: ['Lecture', 'Revision', 'DPP', 'PYQ', 'Mock'].map((type) {
                      return Padding(
                        padding: const EdgeInsets.only(right: 8.0),
                        child: AnimatedToggleChip(
                          label: type,
                          isSelected: _activityType == type,
                          onSelected: _isSessionActive ? () {} : () => setState(() => _activityType = type),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                
                const SizedBox(height: 24),
                
                // TARGET SUBJECT & LEC #
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("TARGET SUBJECT", style: TextStyle(color: secondaryColor, fontSize: 10, letterSpacing: 1.5, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                            decoration: BoxDecoration(
                              color: isDark ? const Color(0xFF1E293B) : Colors.white.withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: _selectedSubject,
                                isExpanded: true,
                                dropdownColor: isDark ? const Color(0xFF1E293B) : Colors.white,
                                style: TextStyle(color: primaryColor, fontSize: 16, fontWeight: FontWeight.w500),
                                icon: Icon(Icons.keyboard_arrow_down, color: secondaryColor),
                                items: ['Physics', 'Chemistry', 'Maths'].map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
                                onChanged: _isSessionActive ? null : (val) => setState(() => _selectedSubject = val!),
                              ),
                            ),
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
                            Text("LEC #", style: TextStyle(color: secondaryColor, fontSize: 10, letterSpacing: 1.5, fontWeight: FontWeight.w700)),
                            const SizedBox(height: 12),
                            PremiumTextField(
                              controller: _lectureController,
                              hintText: "1",
                              keyboardType: TextInputType.number,
                              enabled: !_isSessionActive,
                              onChanged: (val) => _lectureNumber = int.tryParse(val) ?? 1,
                            ),
                          ],
                        ),
                      ),
                    ]
                  ],
                ),
                
                const SizedBox(height: 24),
                
                // CHAPTER CONTEXT
                Text("CHAPTER CONTEXT", style: TextStyle(color: secondaryColor, fontSize: 10, letterSpacing: 1.5, fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                PremiumTextField(
                  controller: _chapterController,
                  hintText: "Enter chapter context...",
                  enabled: !_isSessionActive,
                  onChanged: (val) => _chapterName = val,
                ),

                const SizedBox(height: 32),
                
                // START BUTTON
                GestureDetector(
                  onTap: _toggleSession,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutCubic,
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: _isSessionActive 
                            ? [Colors.redAccent, Colors.red.shade700]
                            : (isDark ? [const Color(0xFF38BDF8), const Color(0xFF0284C7)] : [const Color(0xFF1E293B), const Color(0xFF0F172A)]),
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: _isSessionActive ? Colors.redAccent.withValues(alpha: 0.3) : Colors.black.withValues(alpha: 0.2),
                          blurRadius: 15,
                          offset: const Offset(0, 8),
                        )
                      ],
                    ),
                    child: Text(
                      _isSessionActive ? "Stop Focus Session" : "Start Focus Session",
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ),
                
                const SizedBox(height: 32), 
              ],
            ),
          ),
        ),

        // BOTTOM NAV PLACEHOLDER (Attached to left pane)
        Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: isDark ? Colors.white10 : Colors.black12)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              GestureDetector(
                onTap: () => setState(() => _bottomNavIndex = 0),
                child: Row(
                  children: [
                    Icon(Icons.folder_outlined, color: _bottomNavIndex == 0 ? primaryColor : secondaryColor, size: 18),
                    const SizedBox(width: 8),
                    Text("Focus Engine", style: TextStyle(color: _bottomNavIndex == 0 ? primaryColor : secondaryColor, fontSize: 12, fontWeight: _bottomNavIndex == 0 ? FontWeight.w600 : FontWeight.w500)),
                  ],
                ),
              ),
              const SizedBox(width: 40),
              GestureDetector(
                onTap: () => setState(() => _bottomNavIndex = 1),
                child: Row(
                  children: [
                    Icon(Icons.history, color: _bottomNavIndex == 1 ? primaryColor : secondaryColor, size: 18),
                    const SizedBox(width: 8),
                    Text("Study History", style: TextStyle(color: _bottomNavIndex == 1 ? primaryColor : secondaryColor, fontSize: 12, fontWeight: _bottomNavIndex == 1 ? FontWeight.w600 : FontWeight.w500)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStudyTimeline(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Container(
      color: isDark ? Colors.black.withValues(alpha: 0.1) : Colors.white.withValues(alpha: 0.1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 32, 32, 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  "Study Timeline",
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                Icon(Icons.more_horiz, color: isDark ? Colors.white54 : Colors.black54),
              ],
            ),
          ),
          Expanded(
            child: _isLoadingHistory
                ? const Center(child: CircularProgressIndicator())
                : _sessionHistory.isEmpty
                    ? Center(
                        child: Text(
                          "No sessions yet.",
                          style: TextStyle(color: isDark ? Colors.white54 : Colors.black54),
                        ),
                      )
                    : ListView.builder(
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
                        itemCount: _sessionHistory.length,
                        itemBuilder: (context, index) {
                          final session = _sessionHistory[index];
                          return StudyTimelineCard(
                            session: session,
                            isActive: session['status'] == 'active',
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
