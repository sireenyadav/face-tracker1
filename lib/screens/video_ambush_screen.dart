import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:google_fonts/google_fonts.dart';
import '../telemetry/webrtc_stream_handler.dart';

// ─────────────────────────────────────────────────────────────────────────────
// VideoAmbushScreen
//
// Shown as a full-screen transparent overlay when a parent initiates a
// WebRTC video call.  Displays a 3-second animated countdown before going
// live, then streams camera footage to the parent.  When complete, pops
// itself (triggering dispose → _webRTCHandler.dispose()) so there is no
// invisible 1×1 widget keeping the camera alive.
// ─────────────────────────────────────────────────────────────────────────────

class VideoAmbushScreen extends StatefulWidget {
  final String sessionId;
  const VideoAmbushScreen({super.key, required this.sessionId});

  @override
  State<VideoAmbushScreen> createState() => _VideoAmbushScreenState();
}

class _VideoAmbushScreenState extends State<VideoAmbushScreen>
    with TickerProviderStateMixin {
  late WebRTCStreamHandler _webRTCHandler;

  // Phase flags
  bool _isInitializing = true; // WebRTC not yet ready
  bool _isCountingDown = true; // Showing "Parent is watching in 3…2…1"
  bool _isLive = false;         // Showing live feed

  // Countdown
  int _countdownValue = 3;
  Timer? _countdownTimer;

  // Number scale animation
  late AnimationController _numberController;
  late Animation<double> _numberScale;
  late Animation<double> _numberOpacity;

  @override
  void initState() {
    super.initState();

    _webRTCHandler = WebRTCStreamHandler(sessionId: widget.sessionId);
    _webRTCHandler.onStopAmbush = () {
      if (mounted) Navigator.of(context).pop();
    };

    _numberController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _numberScale = Tween<double>(begin: 1.6, end: 1.0).animate(
      CurvedAnimation(parent: _numberController, curve: Curves.elasticOut),
    );
    _numberOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _numberController,
        curve: const Interval(0.0, 0.4, curve: Curves.easeIn),
      ),
    );

    // Start WebRTC initialisation and countdown in parallel so the stream
    // is ready (or nearly so) by the time the countdown hits 0.
    _initializeWebRTC();
    _startCountdown();
  }

  Future<void> _initializeWebRTC() async {
    await _webRTCHandler.initialize();
    if (mounted) {
      setState(() => _isInitializing = false);
    }
  }

  void _startCountdown() {
    _countdownValue = 3;
    _numberController.forward(from: 0.0);

    _countdownTimer =
        Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }

      if (_countdownValue <= 1) {
        timer.cancel();
        // Transition to live
        if (mounted) {
          setState(() {
            _isCountingDown = false;
            _isLive = true;
          });
        }
        return;
      }

      setState(() => _countdownValue--);
      _numberController.forward(from: 0.0);
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _numberController.dispose();
    _webRTCHandler.dispose();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_isCountingDown) {
      return _buildCountdownOverlay();
    }
    return _buildLiveFeed();
  }

  // ── Countdown overlay ─────────────────────────────────────────────────────

  Widget _buildCountdownOverlay() {
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: 0.85),
      body: SafeArea(
        child: Stack(
          children: [
            // Close button
            Positioned(
              top: 16,
              right: 16,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white60, size: 28),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),

            // Centered content
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Warning icon
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.redAccent.withValues(alpha: 0.12),
                      border: Border.all(
                        color: Colors.redAccent.withValues(alpha: 0.4),
                        width: 1.5,
                      ),
                    ),
                    child: const Icon(
                      Icons.videocam_rounded,
                      color: Colors.redAccent,
                      size: 40,
                    ),
                  ),

                  const SizedBox(height: 32),

                  Text(
                    'Parent is watching in',
                    style: GoogleFonts.inter(
                      color: Colors.white70,
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Animated countdown number
                  AnimatedBuilder(
                    animation: _numberController,
                    builder: (_, __) {
                      return Opacity(
                        opacity: _numberOpacity.value,
                        child: Transform.scale(
                          scale: _numberScale.value,
                          child: Text(
                            '$_countdownValue',
                            style: GoogleFonts.playfairDisplay(
                              color: Colors.white,
                              fontSize: 96,
                              fontWeight: FontWeight.w700,
                              height: 1,
                            ),
                          ),
                        ),
                      );
                    },
                  ),

                  const SizedBox(height: 36),

                  Text(
                    'Sit up straight and focus! 📚',
                    style: GoogleFonts.inter(
                      color: Colors.white38,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Live feed ─────────────────────────────────────────────────────────────

  Widget _buildLiveFeed() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Camera feed or initialising spinner
          if (_isInitializing)
            const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Colors.redAccent),
                  SizedBox(height: 16),
                  Text(
                    'Establishing Secure Video Link...',
                    style: TextStyle(
                        color: Colors.white, fontFamily: 'monospace'),
                  ),
                ],
              ),
            )
          else
            Positioned.fill(
              child: RTCVideoView(
                _webRTCHandler.localRenderer,
                objectFit:
                    RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                mirror: true,
              ),
            ),

          // LIVE badge — top left
          Positioned(
            top: 40,
            left: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.redAccent.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                children: [
                  Icon(Icons.fiber_manual_record,
                      color: Colors.white, size: 10),
                  SizedBox(width: 8),
                  Text(
                    'LIVE FEED ACTIVE',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Close button — top right
          Positioned(
            top: 32,
            right: 20,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 30),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),

          // Bottom info text
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Center(
              child: Text(
                'Parent is currently watching.\n'
                'Telemetry overlays are handled via Vercel dashboard.',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  color: Colors.white60,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
