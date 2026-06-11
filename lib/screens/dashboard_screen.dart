import 'dart:async';
import 'dart:convert';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../theme/app_theme.dart';
import '../components/glass_container.dart';
import '../components/premium_text_field.dart';
import '../components/animated_mesh_background.dart';
import '../components/study_timeline_card.dart';
import 'calibration_screen.dart';
import 'history_screen.dart';
import 'video_ambush_screen.dart';

// ── Subject accent colours ────────────────────────────────────────────────
const Color _physicsColor = Color(0xFF38BDF8);   // sky blue
const Color _chemistryColor = Color(0xFF34D399); // emerald
const Color _mathsColor = Color(0xFFA78BFA);     // violet
const Color _emeraldColor = Color(0xFF10B981);

Color _subjectColor(String subject) {
  switch (subject) {
    case 'Chemistry':
      return _chemistryColor;
    case 'Maths':
      return _mathsColor;
    case 'Physics':
    default:
      return _physicsColor;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with TickerProviderStateMixin {
  // ── Channels ──────────────────────────────────────────────────────────────
  static const platform = MethodChannel('com.facetracker/control');
  static const telemetryStream = EventChannel('com.facetracker/telemetryStream');
  static const syncStream = EventChannel('com.facetracker/syncStream');
  static const _neckStrainChannel =
      BasicMessageChannel<dynamic>('com.facetracker/broadcastReceiver', StandardMessageCodec());

  StreamSubscription? _telemetrySubscription;
  StreamSubscription? _syncSubscription;

  RealtimeChannel? _presenceChannel;
  Timer? _keepAliveTimer;

  // ── Live telemetry ────────────────────────────────────────────────────────
  int _liveScore = 100;
  String _liveState = 'Initializing...';
  bool _isLiveStreaming = false;

  // ── Session state ─────────────────────────────────────────────────────────
  bool _isSessionActive = false;
  String _currentSessionId = '';

  // ValueNotifier for the elapsed timer — prevents full-tree setState every second
  final ValueNotifier<int> _elapsedSecondsNotifier = ValueNotifier<int>(0);
  Timer? _timer;

  // ── DB + UI state ─────────────────────────────────────────────────────────
  String _selectedSubject = 'Physics';
  String _activityType = 'Lecture';
  String _chapterName = '';
  int _lectureNumber = 1;
  final TextEditingController _chapterController = TextEditingController();
  final TextEditingController _lectureController =
      TextEditingController(text: '1');

  // ── Animations ────────────────────────────────────────────────────────────
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // ── Bottom nav + history ──────────────────────────────────────────────────
  int _bottomNavIndex = 0;
  List<Map<String, dynamic>> _sessionHistory = [];
  bool _isLoadingHistory = true;

  // ── Sparkline (last 10 focus scores) ─────────────────────────────────────
  final List<double> _recentScores = [];

  // ── Calibration values ────────────────────────────────────────────────────

  // ── NECK_STRAIN broadcast receiver ───────────────────────────────────────
  // We set up a handler on the BasicMessageChannel to receive native events.
  // The Kotlin side can send a message on this channel when the intent arrives.

  @override
  void initState() {
    super.initState();

    _checkSupabaseConnection();
    _fetchSessionHistory();
    _loadCalibrationPrefs();
    _setupNeckStrainListener();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    _pulseAnimation =
        Tween<double>(begin: 1.0, end: 1.02).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOutSine),
    );
  }

  // ── Calibration prefs ─────────────────────────────────────────────────────

  Future<void> _loadCalibrationPrefs() async {
    // Calibration parameters have been removed.
  }

  Future<void> _openCalibrationScreen() async {
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(builder: (_) => const CalibrationScreen()),
    );
    if (result != null) {
      // Calibration parameters have been removed.
    }
  }

  // ── Neck strain ───────────────────────────────────────────────────────────

  void _setupNeckStrainListener() {
    _neckStrainChannel.setMessageHandler((dynamic message) async {
      if (!mounted) return null;
      final msg = message?.toString() ?? '';
      if (msg.contains('NECK_STRAIN') ||
          msg.contains('posture') ||
          msg.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Text('🧘', style: TextStyle(fontSize: 18)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Sit up straight! Your posture needs attention.',
                    style: GoogleFonts.inter(
                      color: Colors.black87,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            backgroundColor: const Color(0xFFFBBF24),
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            duration: const Duration(seconds: 4),
          ),
        );
      }
      return null;
    });
  }

  // ── Supabase ──────────────────────────────────────────────────────────────

  void _checkSupabaseConnection() async {
    try {
      await Supabase.instance.client
          .from('focus_sessions')
          .select('id')
          .limit(1);
    } catch (e) {
      // Ignore
    }
  }

  Future<void> _fetchSessionHistory() async {
    try {
      final data = await Supabase.instance.client
          .from('focus_sessions')
          .select(
            'id, subject_tag, activity_type, chapter_name, lecture_number, '
            'started_at, ended_at, status, avg_focus_score, peak_focus_score',
          )
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

  // ── WebRTC signaling ──────────────────────────────────────────────────────

  void _listenForVideoRequests(String sessionId) {
    Supabase.instance.client
        .channel('signaling_trigger_$sessionId')
        .onPostgresChanges(
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
          },
        )
        .subscribe();
  }

  void _triggerVideoAmbushOverlay(String sessionId) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        pageBuilder: (context, animation, secondaryAnimation) =>
            VideoAmbushScreen(sessionId: sessionId),
        fullscreenDialog: true,
      ),
    );
  }

  // ── Dispose ───────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _chapterController.dispose();
    _lectureController.dispose();
    _telemetrySubscription?.cancel();
    _syncSubscription?.cancel();
    _timer?.cancel();
    _pulseController.dispose();
    _elapsedSecondsNotifier.dispose();
    _neckStrainChannel.setMessageHandler(null);
    
    _keepAliveTimer?.cancel();
    _presenceChannel?.untrack();
    if (_presenceChannel != null) {
      Supabase.instance.client.removeChannel(_presenceChannel!);
    }
    super.dispose();
  }

  // ── Permissions ───────────────────────────────────────────────────────────

  Future<bool> _requestPermissions() async {
    Map<Permission, PermissionStatus> statuses =
        await [Permission.camera, Permission.notification, Permission.systemAlertWindow].request();
    return statuses[Permission.camera]!.isGranted &&
        statuses[Permission.notification]!.isGranted &&
        statuses[Permission.systemAlertWindow]!.isGranted;
  }

  // ── Session toggle ────────────────────────────────────────────────────────

  void _toggleSession() async {
    if (_isSessionActive) {
      // ── STOP ────────────────────────────────────────────────────────────
      HapticFeedback.mediumImpact();

      _telemetrySubscription?.cancel();
      _syncSubscription?.cancel();
      _timer?.cancel();
      _pulseController.stop();
      _pulseController.reset();

      // Presence & Keep-Alive cleanup
      _keepAliveTimer?.cancel();
      _presenceChannel?.untrack();
      if (_presenceChannel != null) {
        Supabase.instance.client.removeChannel(_presenceChannel!);
        _presenceChannel = null;
      }

      // Finalize session via RPC BEFORE stopping native service
      try {
        await Supabase.instance.client.rpc(
          'finalize_session',
          params: {'p_session_id': _currentSessionId},
        );
      } catch (e) {
        debugPrint('finalize_session RPC failed: $e');
      }

      try {
        Supabase.instance.client.removeChannel(
          Supabase.instance.client
              .channel('signaling_trigger_$_currentSessionId'),
        );
        await Supabase.instance.client.from('focus_sessions').update({
          'status': 'completed',
          'ended_at': DateTime.now().toUtc().toIso8601String(),
        }).eq('id', _currentSessionId);
      } catch (_) {}

      try {
        await platform.invokeMethod('stopService');
      } catch (e) {
        debugPrint('Failed to stop service: $e');
      }

      setState(() {
        _isSessionActive = false;
        _recentScores.clear();
      });
      _fetchSessionHistory();
    } else {
      // ── START ────────────────────────────────────────────────────────────
      if (!await _requestPermissions()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Camera permissions required.')),
          );
        }
        return;
      }

      HapticFeedback.heavyImpact();

      final newSessionId = const Uuid().v4();
      _elapsedSecondsNotifier.value = 0;

      setState(() {
        _liveScore = 100;
        _liveState = 'Initializing...';
        _isSessionActive = true;
        _currentSessionId = newSessionId;
        _recentScores.clear();
      });

      // Insert session record
      try {
        await Supabase.instance.client.from('focus_sessions').insert({
          'id': newSessionId,
          'user_id': Supabase.instance.client.auth.currentUser?.id ??
              '00000000-0000-0000-0000-000000000000',
          'subject_tag': _selectedSubject,
          'target_exam': 'JEE',
          'activity_type': _activityType,
          'chapter_name': _chapterName,
          'lecture_number':
              _activityType == 'Lecture' ? _lectureNumber : 0,
          'status': 'active',
          'started_at': DateTime.now().toUtc().toIso8601String(),
        });
      } catch (e) {
        debugPrint('Failed to insert session: $e');
      }

      _pulseController.repeat(reverse: true);

      // Build config with calibration values
      final calibPrefs = await SharedPreferences.getInstance();
      final configJson = jsonEncode({
        'sessionId': _currentSessionId,
        'subjectTag': _selectedSubject,
        'targetExam': 'JEE',
        'activityType': _activityType,
        'chapterName': _chapterName,
        'lectureNumber': _activityType == 'Lecture' ? _lectureNumber : 0,
        'baselineYaw':
            calibPrefs.getDouble('calib_baseline_yaw') ?? 0.0,
        'baselinePitch':
            calibPrefs.getDouble('calib_baseline_pitch') ?? 0.0,
        'sigmaYaw':
            calibPrefs.getDouble('calib_sigma_yaw') ?? 35.0,
        'sigmaPitch':
            calibPrefs.getDouble('calib_sigma_pitch') ?? 40.0,
      });

      try {
        await platform.invokeMethod('startService', {'config': configJson});

        _telemetrySubscription =
            telemetryStream.receiveBroadcastStream().listen((event) {
          final data = Map<String, dynamic>.from(event as Map);
          if (mounted) {
            setState(() {
              _liveScore = (data['score'] as num?)?.toInt() ?? 100;
              _liveState = data['state'] as String? ?? 'Unknown';
              // Update sparkline
              _recentScores.add(_liveScore.toDouble());
              if (_recentScores.length > 10) {
                _recentScores.removeAt(0);
              }
            });
          }
        });

        _syncSubscription =
            syncStream.receiveBroadcastStream().listen((event) {
          final data = Map<String, dynamic>.from(event as Map);
          if (mounted) {
            setState(() {
              _isLiveStreaming = data['isLive'] as bool? ?? false;
            });
          }
        });
      } catch (e) {
        debugPrint('Failed to start service: $e');
      }

      // Timer now only updates the ValueNotifier — no full setState
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        _elapsedSecondsNotifier.value++;
      });

      // Presence
      _presenceChannel = Supabase.instance.client.channel('presence:focus_sessions');
      _presenceChannel?.subscribe((status, error) {
        if (status == RealtimeSubscribeStatus.subscribed) {
          _presenceChannel?.track({
            'session_id': _currentSessionId,
            'status': 'online',
          });
        }
      });

      // Keep-alive for pg_cron
      _keepAliveTimer = Timer.periodic(const Duration(seconds: 10), (_) {
        try {
          Supabase.instance.client.from('focus_sessions').update({
            'last_telemetry_at': DateTime.now().toUtc().toIso8601String(),
          }).eq('id', _currentSessionId);
        } catch (_) {}
      });

      _listenForVideoRequests(_currentSessionId);
      _fetchSessionHistory();
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _formatElapsedTime(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}';
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return AnimatedMeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isLandscape = constraints.maxWidth > constraints.maxHeight;
              return isLandscape
                  ? _buildLandscapeLayout(context)
                  : _buildPortraitLayout(context);
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
            Expanded(flex: 6, child: _buildControlHub(context)),
            Container(
              width: 1,
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.white10
                  : Colors.black12,
            ),
            Expanded(
              flex: 4,
              child: IndexedStack(
                index: _bottomNavIndex,
                children: [
                  _buildStudyTimeline(context),
                  _buildHistoryPanel(context),
                ],
              ),
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
                height: 500,
                child: IndexedStack(
                  index: _bottomNavIndex,
                  children: [
                    _buildStudyTimeline(context),
                    _buildHistoryPanel(context),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Control hub ───────────────────────────────────────────────────────────

  Widget _buildControlHub(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? Colors.white : Colors.black87;
    final secondaryColor = isDark ? Colors.white54 : Colors.black54;
    final subjectAccent = _subjectColor(_selectedSubject);

    return Column(
      children: [
        // ── HEADER ─────────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 32, 32, 16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Focus Control Hub',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                        color: primaryColor,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    // Sync status chip
                    _buildSyncChip(isDark),
                  ],
                ),
              ),
              // Calibrate button
              TextButton.icon(
                onPressed: _isSessionActive ? null : _openCalibrationScreen,
                icon: Icon(Icons.tune_rounded,
                    size: 16, color: _isSessionActive ? secondaryColor : subjectAccent),
                label: Text(
                  'Calibrate',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: _isSessionActive ? secondaryColor : subjectAccent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: Icon(Icons.notifications_none,
                    color: secondaryColor, size: 20),
                onPressed: () {},
              ),
              IconButton(
                icon: Icon(
                  isDark ? Icons.light_mode : Icons.dark_mode_outlined,
                  color: secondaryColor,
                  size: 20,
                ),
                onPressed: () => themeProvider.toggleTheme(),
              ),
              Icon(Icons.battery_full, color: secondaryColor, size: 20),
            ],
          ),
        ),

        // ── MAIN SCROLLABLE CONTENT ─────────────────────────────────────────
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding:
                const EdgeInsets.symmetric(horizontal: 32.0, vertical: 8.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Stopwatch card
                AnimatedBuilder(
                  animation: _pulseAnimation,
                  builder: (context, child) => Transform.scale(
                    scale: _isSessionActive ? _pulseAnimation.value : 1.0,
                    child: child,
                  ),
                  child: GlassContainer(
                    blur: 20,
                    opacity: isDark ? 0.05 : 0.4,
                    padding: const EdgeInsets.symmetric(
                        vertical: 40, horizontal: 20),
                    child: Column(
                      children: [
                        Text(
                          'ELAPSED TIME',
                          style: TextStyle(
                            color: secondaryColor,
                            fontSize: 10,
                            letterSpacing: 2,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 12),

                        // ValueListenableBuilder — ONLY the timer rebuilds each second
                        ValueListenableBuilder<int>(
                          valueListenable: _elapsedSecondsNotifier,
                          builder: (_, seconds, __) {
                            return AnimatedSwitcher(
                              duration: const Duration(milliseconds: 300),
                              child: Text(
                                _formatElapsedTime(seconds),
                                key: ValueKey(seconds),
                                style: GoogleFonts.playfairDisplay(
                                  color: primaryColor,
                                  fontSize: 64,
                                  fontWeight: FontWeight.w500,
                                  letterSpacing: 2,
                                ),
                              ),
                            );
                          },
                        ),

                        AnimatedSize(
                          duration: const Duration(milliseconds: 400),
                          curve: Curves.easeOutExpo,
                          child: _isSessionActive
                              ? Column(
                                  children: [
                                    const SizedBox(height: 20),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          '$_liveScore',
                                          style: GoogleFonts.playfairDisplay(
                                            fontSize: 42,
                                            fontWeight: FontWeight.w600,
                                            color: _liveScore >= 75
                                                ? _emeraldColor
                                                : Colors.redAccent,
                                          ),
                                        ),
                                        Text(
                                          ' %',
                                          style: TextStyle(
                                            fontSize: 20,
                                            color: _liveScore >= 75
                                                ? _emeraldColor.withValues(
                                                    alpha: 0.7)
                                                : Colors.redAccent.withValues(
                                                    alpha: 0.7),
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
                                    ),
                                    // ── Sparkline ──────────────────────────
                                    if (_recentScores.length >= 2) ...[
                                      const SizedBox(height: 20),
                                      _buildSparkline(isDark),
                                    ],
                                  ],
                                )
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 32),

                // ACTIVITY TYPE
                Text(
                  'ACTIVITY TYPE',
                  style: TextStyle(
                      color: secondaryColor,
                      fontSize: 10,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  child: Row(
                    children: ['Lecture', 'Revision', 'DPP', 'PYQ', 'Mock']
                        .map((type) {
                      return Padding(
                        padding: const EdgeInsets.only(right: 8.0),
                        child: _buildColoredChip(
                          label: type,
                          isSelected: _activityType == type,
                          accentColor: subjectAccent,
                          onSelected: _isSessionActive
                              ? () {}
                              : () =>
                                  setState(() => _activityType = type),
                          isDark: isDark,
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
                          Text(
                            'TARGET SUBJECT',
                            style: TextStyle(
                                color: secondaryColor,
                                fontSize: 10,
                                letterSpacing: 1.5,
                                fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 4),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? const Color(0xFF1E293B)
                                  : Colors.white.withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isDark
                                    ? subjectAccent.withValues(alpha: 0.3)
                                    : const Color(0xFFE2E8F0),
                                width: 1.5,
                              ),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: _selectedSubject,
                                isExpanded: true,
                                dropdownColor: isDark
                                    ? const Color(0xFF1E293B)
                                    : Colors.white,
                                style: TextStyle(
                                    color: subjectAccent,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600),
                                icon: Icon(Icons.keyboard_arrow_down,
                                    color: subjectAccent.withValues(alpha: 0.7)),
                                items: ['Physics', 'Chemistry', 'Maths']
                                    .map((s) => DropdownMenuItem(
                                          value: s,
                                          child: Row(
                                            children: [
                                              Container(
                                                width: 8,
                                                height: 8,
                                                margin: const EdgeInsets.only(
                                                    right: 8),
                                                decoration: BoxDecoration(
                                                  shape: BoxShape.circle,
                                                  color: _subjectColor(s),
                                                ),
                                              ),
                                              Text(s,
                                                  style: TextStyle(
                                                    color: _subjectColor(s),
                                                    fontWeight:
                                                        FontWeight.w600,
                                                  )),
                                            ],
                                          ),
                                        ))
                                    .toList(),
                                onChanged: _isSessionActive
                                    ? null
                                    : (val) => setState(
                                        () => _selectedSubject = val!),
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
                            Text(
                              'LEC #',
                              style: TextStyle(
                                  color: secondaryColor,
                                  fontSize: 10,
                                  letterSpacing: 1.5,
                                  fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 12),
                            PremiumTextField(
                              controller: _lectureController,
                              hintText: '1',
                              keyboardType: TextInputType.number,
                              enabled: !_isSessionActive,
                              onChanged: (val) =>
                                  _lectureNumber = int.tryParse(val) ?? 1,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),

                const SizedBox(height: 24),

                // CHAPTER CONTEXT
                Text(
                  'CHAPTER CONTEXT',
                  style: TextStyle(
                      color: secondaryColor,
                      fontSize: 10,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                PremiumTextField(
                  controller: _chapterController,
                  hintText: 'Enter chapter context...',
                  enabled: !_isSessionActive,
                  onChanged: (val) => _chapterName = val,
                ),

                const SizedBox(height: 32),

                // START / STOP BUTTON
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
                            : (isDark
                                ? [
                                    subjectAccent,
                                    subjectAccent.withValues(alpha: 0.7)
                                  ]
                                : [
                                    const Color(0xFF1E293B),
                                    const Color(0xFF0F172A)
                                  ]),
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: _isSessionActive
                              ? Colors.redAccent.withValues(alpha: 0.3)
                              : subjectAccent.withValues(alpha: 0.25),
                          blurRadius: 15,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Text(
                      _isSessionActive
                          ? 'Stop Focus Session'
                          : 'Start Focus Session',
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

        // ── BOTTOM NAV ──────────────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: isDark ? Colors.white10 : Colors.black12,
              ),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              GestureDetector(
                onTap: () => setState(() => _bottomNavIndex = 0),
                child: Row(
                  children: [
                    Icon(
                      Icons.folder_outlined,
                      color: _bottomNavIndex == 0
                          ? primaryColor
                          : secondaryColor,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Focus Engine',
                      style: TextStyle(
                        color: _bottomNavIndex == 0
                            ? primaryColor
                            : secondaryColor,
                        fontSize: 12,
                        fontWeight: _bottomNavIndex == 0
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 40),
              GestureDetector(
                onTap: () => setState(() => _bottomNavIndex = 1),
                child: Row(
                  children: [
                    Icon(
                      Icons.history,
                      color: _bottomNavIndex == 1
                          ? primaryColor
                          : secondaryColor,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Study History',
                      style: TextStyle(
                        color: _bottomNavIndex == 1
                            ? primaryColor
                            : secondaryColor,
                        fontSize: 12,
                        fontWeight: _bottomNavIndex == 1
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Sync chip ─────────────────────────────────────────────────────────────

  Widget _buildSyncChip(bool isDark) {
    final synced = _isLiveStreaming;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: synced
            ? const Color(0xFF34D399).withValues(alpha: 0.15)
            : const Color(0xFFFBBF24).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: synced
              ? const Color(0xFF34D399).withValues(alpha: 0.4)
              : const Color(0xFFFBBF24).withValues(alpha: 0.4),
        ),
      ),
      child: Text(
        synced ? '⚡ Synced' : '⏳ Pending',
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: synced ? const Color(0xFF34D399) : const Color(0xFFFBBF24),
        ),
      ),
    );
  }

  // ── Sparkline chart ───────────────────────────────────────────────────────

  Widget _buildSparkline(bool isDark) {
    final spots = _recentScores.asMap().entries.map((e) {
      return FlSpot(e.key.toDouble(), e.value);
    }).toList();

    final lineColor = _recentScores.last >= 75
        ? _emeraldColor
        : Colors.redAccent;

    return SizedBox(
      height: 60,
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: 100,
          gridData: const FlGridData(show: false),
          titlesData: const FlTitlesData(show: false),
          borderData: FlBorderData(show: false),
          lineTouchData: const LineTouchData(enabled: false),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              color: lineColor,
              barWidth: 2.5,
              isStrokeCapRound: true,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: lineColor.withValues(alpha: 0.12),
              ),
            ),
          ],
        ),
        duration: const Duration(milliseconds: 150),
      ),
    );
  }

  // ── Subject-colored chip ──────────────────────────────────────────────────

  Widget _buildColoredChip({
    required String label,
    required bool isSelected,
    required Color accentColor,
    required VoidCallback onSelected,
    required bool isDark,
  }) {
    final bgColor = isSelected
        ? accentColor
        : (isDark ? const Color(0xFF1E293B) : Colors.white);
    final textColor = isSelected
        ? Colors.white
        : (isDark ? Colors.white70 : Colors.black87);
    final borderColor = isSelected
        ? Colors.transparent
        : (isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0));

    return GestureDetector(
      onTap: onSelected,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(12.0),
          border: Border.all(color: borderColor, width: 1),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: accentColor.withValues(alpha: 0.3),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ]
              : [],
        ),
        child: Text(
          label,
          style: TextStyle(
            color: textColor,
            fontWeight:
                isSelected ? FontWeight.w600 : FontWeight.w500,
            fontSize: 14,
          ),
        ),
      ),
    );
  }

  // ── Study timeline (index 0 right panel) ──────────────────────────────────

  Widget _buildStudyTimeline(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      color: isDark
          ? Colors.black.withValues(alpha: 0.1)
          : Colors.white.withValues(alpha: 0.1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 32, 32, 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Study Timeline',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                Icon(Icons.more_horiz,
                    color: isDark ? Colors.white54 : Colors.black54),
              ],
            ),
          ),
          Expanded(
            child: _isLoadingHistory
                ? const Center(child: CircularProgressIndicator())
                : _sessionHistory.isEmpty
                    ? Center(
                        child: Text(
                          'No sessions yet.',
                          style: TextStyle(
                              color: isDark ? Colors.white54 : Colors.black54),
                        ),
                      )
                    : ListView.builder(
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 32, vertical: 8),
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

  // ── History inline panel (index 1 right panel) ────────────────────────────

  Widget _buildHistoryPanel(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      color: isDark
          ? Colors.black.withValues(alpha: 0.1)
          : Colors.white.withValues(alpha: 0.1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 32, 32, 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Session History',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                GestureDetector(
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const HistoryScreen()),
                    );
                  },
                  child: Text(
                    'Full View →',
                    style: TextStyle(
                      fontSize: 13,
                      color: _subjectColor(_selectedSubject),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _isLoadingHistory
                ? const Center(child: CircularProgressIndicator())
                : _sessionHistory.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('📚',
                                style: TextStyle(fontSize: 40)),
                            const SizedBox(height: 12),
                            Text(
                              'No sessions yet.\nStart your first focus session!',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: isDark
                                    ? Colors.white54
                                    : Colors.black54,
                                fontSize: 14,
                                height: 1.6,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        itemCount: _sessionHistory.length,
                        itemBuilder: (context, index) {
                          final session = _sessionHistory[index];
                          return _buildCompactHistoryCard(
                              session, isDark);
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactHistoryCard(
      Map<String, dynamic> session, bool isDark) {
    final subject = session['subject_tag'] as String? ?? 'Unknown';
    final activity = session['activity_type'] as String? ?? 'General';
    final chapter = session['chapter_name'] as String? ?? '';
    final status = session['status'] as String? ?? '';
    final avgScore = (session['avg_focus_score'] as num?)?.toDouble();
    final subjectColor = _subjectColor(subject);

    Color scoreColor = Colors.grey;
    if (avgScore != null) {
      scoreColor = avgScore >= 80
          ? const Color(0xFF34D399)
          : avgScore >= 60
              ? const Color(0xFFFBBF24)
              : Colors.redAccent;
    }

    String duration = 'Active Now';
    if (status != 'active' &&
        session['started_at'] != null &&
        session['ended_at'] != null) {
      final start = DateTime.parse(session['started_at'] as String);
      final end = DateTime.parse(session['ended_at'] as String);
      final diff = end.difference(start);
      duration = '${diff.inMinutes} min';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.04)
              : Colors.white.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isDark ? Colors.white10 : Colors.black12,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: subjectColor,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    subject,
                    style: TextStyle(
                      color: isDark ? Colors.white : Colors.black87,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  if (chapter.isNotEmpty)
                    Text(
                      chapter,
                      style: TextStyle(
                        color:
                            isDark ? Colors.white54 : Colors.black54,
                        fontSize: 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: subjectColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    activity,
                    style: TextStyle(
                      color: subjectColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                if (avgScore != null)
                  Text(
                    '${avgScore.toStringAsFixed(0)}%',
                    style: TextStyle(
                      color: scoreColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  )
                else
                  Text(
                    duration,
                    style: TextStyle(
                      color: status == 'active'
                          ? Colors.redAccent
                          : (isDark ? Colors.white38 : Colors.black38),
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
