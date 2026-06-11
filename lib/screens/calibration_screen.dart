import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../components/animated_mesh_background.dart';

// ---------------------------------------------------------------------------
// CalibrationScreen
// 30-second guided head-pose calibration using a native MethodChannel call.
// ---------------------------------------------------------------------------
class CalibrationScreen extends StatefulWidget {
  const CalibrationScreen({super.key});

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends State<CalibrationScreen>
    with TickerProviderStateMixin {
  // ── Channels ──────────────────────────────────────────────────────────────
  static const _platform = MethodChannel('com.facetracker/control');

  // ── Countdown animation ───────────────────────────────────────────────────
  late AnimationController _countdownController;
  late Animation<double> _countdownProgress; // 1.0 → 0.0

  int _remainingSeconds = 30;
  Timer? _tickTimer;

  // ── Head-pose stability indicator ─────────────────────────────────────────
  // We animate a "breathing" circle that changes colour based on how stable
  // the head pose is (reported via the calibration result in real-time).
  // Before the native call returns we simply animate randomly to show life.
  late AnimationController _stabilityController;
  late Animation<double> _stabilityPulse;

  // 0.0 = unstable (red) … 1.0 = stable (green)
  double _stabilityFraction = 0.5;

  // ── Success animation ─────────────────────────────────────────────────────
  late AnimationController _successController;
  late Animation<double> _successScale;
  late Animation<double> _successOpacity;

  bool _calibrationDone = false;
  bool _calibrationRunning = false;

  // ── Default / result map ──────────────────────────────────────────────────
  static const Map<String, dynamic> _defaultCalib = {
    'baselineYaw': 0.0,
    'baselinePitch': 0.0,
    'sigmaYaw': 35.0,
    'sigmaPitch': 40.0,
  };

  // ── Stability shimmer animation ───────────────────────────────────────────
  late AnimationController _shimmerController;

  @override
  void initState() {
    super.initState();

    // Countdown arc (sweeps from full → empty over 30 s)
    _countdownController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 30),
    );
    _countdownProgress = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _countdownController, curve: Curves.linear),
    );

    // Stability pulse (looping breathe)
    _stabilityController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _stabilityPulse = Tween<double>(begin: 0.92, end: 1.08).animate(
      CurvedAnimation(parent: _stabilityController, curve: Curves.easeInOutSine),
    );

    // Success scale/opacity
    _successController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _successScale = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _successController, curve: Curves.elasticOut),
    );
    _successOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _successController,
        curve: const Interval(0.0, 0.5, curve: Curves.easeIn),
      ),
    );

    // Shimmer for the outer ring
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();

    // Auto-start calibration
    _startCalibration();
  }

  @override
  void dispose() {
    _countdownController.dispose();
    _stabilityController.dispose();
    _successController.dispose();
    _shimmerController.dispose();
    _tickTimer?.cancel();
    super.dispose();
  }

  // ── Core calibration flow ─────────────────────────────────────────────────

  Future<void> _startCalibration() async {
    if (_calibrationRunning) return;
    _calibrationRunning = true;

    _countdownController.forward(from: 0.0);

    // Tick timer — updates the displayed integer each second
    _remainingSeconds = 30;
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        _remainingSeconds = (30 - (t.tick)).clamp(0, 30);
        // Simulate increasing stability as time goes on
        _stabilityFraction = (t.tick / 30.0).clamp(0.0, 1.0);
      });
      if (t.tick >= 30) t.cancel();
    });

    // ── Native call (blocks for ~30 s on the platform side) ──────────────
    Map<String, dynamic> result = Map.from(_defaultCalib);
    try {
      final dynamic raw = await _platform.invokeMethod('runCalibration');
      if (raw is Map) {
        result = {
          'baselineYaw': (raw['baselineYaw'] as num?)?.toDouble() ?? 0.0,
          'baselinePitch': (raw['baselinePitch'] as num?)?.toDouble() ?? 0.0,
          'sigmaYaw': (raw['sigmaYaw'] as num?)?.toDouble() ?? 35.0,
          'sigmaPitch': (raw['sigmaPitch'] as num?)?.toDouble() ?? 40.0,
        };
      }
    } on PlatformException catch (e) {
      debugPrint('Calibration PlatformException: ${e.message}');
    } catch (e) {
      debugPrint('Calibration error: $e');
    }

    _tickTimer?.cancel();

    if (!mounted) return;

    // Persist to SharedPreferences
    await _persistCalibration(result);

    // Show success animation then pop
    setState(() {
      _calibrationDone = true;
      _remainingSeconds = 0;
      _stabilityFraction = 1.0;
    });

    _successController.forward();

    await Future.delayed(const Duration(milliseconds: 1400));

    if (mounted) {
      Navigator.of(context).pop(result);
    }
  }

  Future<void> _persistCalibration(Map<String, dynamic> result) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('calib_baseline_yaw', result['baselineYaw'] as double);
    await prefs.setDouble('calib_baseline_pitch', result['baselinePitch'] as double);
    await prefs.setDouble('calib_sigma_yaw', result['sigmaYaw'] as double);
    await prefs.setDouble('calib_sigma_pitch', result['sigmaPitch'] as double);
  }

  void _skip() {
    _tickTimer?.cancel();
    _countdownController.stop();
    Navigator.of(context).pop(Map<String, dynamic>.from(_defaultCalib));
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Color _stabilityColor(double fraction) {
    if (fraction < 0.4) return Colors.redAccent;
    if (fraction < 0.7) return const Color(0xFFFBBF24); // amber
    return const Color(0xFF34D399); // emerald
  }

  String _stabilityLabel(double fraction) {
    if (fraction < 0.4) return 'UNSTABLE';
    if (fraction < 0.7) return 'SETTLING';
    return 'STABLE ✓';
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return AnimatedMeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Stack(
            children: [
              // Skip button — top right
              Positioned(
                top: 16,
                right: 16,
                child: TextButton(
                  onPressed: _skip,
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white70,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  ),
                  child: Text(
                    'Skip',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      color: Colors.white54,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),

              // Main content
              Center(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 80),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Title
                      Text(
                        'Head Pose Calibration',
                        style: GoogleFonts.playfairDisplay(
                          fontSize: 32,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                          letterSpacing: -0.5,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Sit naturally. Look at the center of your screen. Stay still.',
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          color: Colors.white60,
                          height: 1.6,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 60),

                      // ── Countdown circle + head-pose indicator ────────────
                      if (!_calibrationDone)
                        _buildCountdownRing()
                      else
                        _buildSuccessCheckmark(),

                      const SizedBox(height: 48),

                      // Stability badge
                      if (!_calibrationDone)
                        _buildStabilityBadge(),

                      const SizedBox(height: 32),

                      // Instructions list
                      if (!_calibrationDone)
                        _buildInstructionsList(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Sub-widgets ───────────────────────────────────────────────────────────

  Widget _buildCountdownRing() {
    final stabColor = _stabilityColor(_stabilityFraction);

    return SizedBox(
      width: 260,
      height: 260,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Outer shimmer ring
          AnimatedBuilder(
            animation: _shimmerController,
            builder: (_, __) {
              return CustomPaint(
                size: const Size(260, 260),
                painter: _ShimmerRingPainter(
                  progress: _shimmerController.value,
                  color: stabColor,
                ),
              );
            },
          ),

          // Countdown arc
          AnimatedBuilder(
            animation: _countdownProgress,
            builder: (_, __) {
              return CustomPaint(
                size: const Size(220, 220),
                painter: _CountdownArcPainter(
                  progress: _countdownProgress.value,
                  color: stabColor,
                ),
              );
            },
          ),

          // Head pose silhouette (stability pulsing circle)
          AnimatedBuilder(
            animation: _stabilityPulse,
            builder: (_, child) {
              return Transform.scale(
                scale: _stabilityPulse.value,
                child: child,
              );
            },
            child: Container(
              width: 140,
              height: 140,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: stabColor.withValues(alpha: 0.12),
                border: Border.all(
                  color: stabColor.withValues(alpha: 0.5),
                  width: 2,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Face silhouette icon
                  Icon(
                    Icons.face_retouching_natural,
                    size: 36,
                    color: stabColor.withValues(alpha: 0.8),
                  ),
                  const SizedBox(height: 8),
                  // Countdown number
                  Text(
                    '$_remainingSeconds',
                    style: GoogleFonts.playfairDisplay(
                      fontSize: 42,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      height: 1,
                    ),
                  ),
                  Text(
                    'sec',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      color: Colors.white38,
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSuccessCheckmark() {
    return AnimatedBuilder(
      animation: _successController,
      builder: (_, __) {
        return Opacity(
          opacity: _successOpacity.value,
          child: Transform.scale(
            scale: _successScale.value,
            child: Container(
              width: 160,
              height: 160,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF34D399).withValues(alpha: 0.15),
                border: Border.all(
                  color: const Color(0xFF34D399).withValues(alpha: 0.6),
                  width: 2.5,
                ),
              ),
              child: const Icon(
                Icons.check_rounded,
                color: Color(0xFF34D399),
                size: 80,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildStabilityBadge() {
    final stabColor = _stabilityColor(_stabilityFraction);
    final label = _stabilityLabel(_stabilityFraction);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 500),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: stabColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: stabColor.withValues(alpha: 0.4), width: 1.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 500),
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: stabColor,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 13,
              color: stabColor,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInstructionsList() {
    final tips = [
      '👀  Keep your gaze centered on the screen',
      '🪑  Sit in your normal study posture',
      '🤫  Avoid nodding or turning your head',
      '💡  Ensure your face is well-lit',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: tips.map((tip) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            tip,
            style: GoogleFonts.inter(
              fontSize: 14,
              color: Colors.white54,
              height: 1.5,
            ),
          ),
        );
      }).toList(),
    );
  }
}

// ---------------------------------------------------------------------------
// Custom Painters
// ---------------------------------------------------------------------------

/// Sweeping arc that represents the countdown progress.
class _CountdownArcPainter extends CustomPainter {
  final double progress; // 1.0 (full) → 0.0 (empty)
  final Color color;

  _CountdownArcPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 6;

    // Track
    final trackPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, trackPaint);

    // Progress arc
    final arcPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,            // start at top
      2 * math.pi * progress,  // sweep
      false,
      arcPaint,
    );
  }

  @override
  bool shouldRepaint(_CountdownArcPainter old) =>
      old.progress != progress || old.color != color;
}

/// Spinning shimmer dashes around the outer ring.
class _ShimmerRingPainter extends CustomPainter {
  final double progress; // 0.0 → 1.0 (looping)
  final Color color;

  _ShimmerRingPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 2;
    const dashCount = 36;
    const dashLength = 0.06; // radians

    final paint = Paint()
      ..color = color.withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;

    for (int i = 0; i < dashCount; i++) {
      final angle = (i / dashCount) * 2 * math.pi + progress * 2 * math.pi;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        angle,
        dashLength,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_ShimmerRingPainter old) =>
      old.progress != progress || old.color != color;
}
