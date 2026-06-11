import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class WebRTCStreamHandler {
  final String sessionId;
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  final SupabaseClient _supabase = Supabase.instance.client;
  
  // Expose the renderer for the tiny preview indicator
  RTCVideoRenderer localRenderer = RTCVideoRenderer();

  WebRTCStreamHandler({required this.sessionId});

  /// Initializes the WebRTC Peer Connection and grabs the specific device camera stream
  Future<void> initialize() async {
    await localRenderer.initialize();

    // Standard free public STUN configuration
    final Map<String, dynamic> configuration = {
      'iceServers': [
        {
          'urls': [
            'stun:stun.l.google.com:19302',
            'stun:stun1.l.google.com:19302'
          ]
        }
      ]
    };

    _peerConnection = await createPeerConnection(configuration);

    // Minimize data consumption & thermal load
    final Map<String, dynamic> mediaConstraints = {
      'audio': true, // Assuming audio is needed for verification, adjust if not.
      'video': {
        'facingMode': 'user',
        'width': {'exact': 480},
        'height': {'exact': 360},
        'frameRate': {'exact': 15},
      }
    };

    try {
      _localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
      localRenderer.srcObject = _localStream;
      
      _localStream!.getTracks().forEach((track) {
        _peerConnection!.addTrack(track, _localStream!);
      });
    } catch (e) {
      debugPrint("CRITICAL: Failed to bind User Media - $e");
    }

    // Serialize and append generated ICE Candidates to Supabase
    _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) async {
      if (candidate.candidate != null) {
        await _supabase.from('webrtc_signaling').insert({
          'session_id': sessionId,
          'type': 'candidate_tablet',
          'payload': candidate.toMap()
        });
      }
    };
    
    // Check if parent already sent an offer while we were initializing camera
    final existingOffer = await _supabase
        .from('webrtc_signaling')
        .select()
        .eq('session_id', sessionId)
        .eq('type', 'offer_parent')
        .order('created_at', ascending: false)
        .limit(1);
        
    if (existingOffer.isNotEmpty) {
      await _handleOffer(existingOffer[0]['payload']);
    }

    // Listen to Supabase Realtime for parent incoming offers and candidate exchanges
    _supabase
        .channel('public:webrtc_signaling')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'webrtc_signaling',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'session_id',
            value: sessionId,
          ),
          callback: (payload) async {
            final newRecord = payload.newRecord;
            
            if (newRecord['type'] == 'offer_parent') {
              await _handleOffer(newRecord['payload']);
            } else if (newRecord['type'] == 'candidate_parent') {
              await _handleRemoteCandidate(newRecord['payload']);
            }
          },
        )
        .subscribe();
  }

  /// Evaluates the SDP Offer, writes local description, and fires back the Answer
  Future<void> _handleOffer(Map<String, dynamic> offerPayload) async {
    try {
      final RTCSessionDescription description = RTCSessionDescription(
        offerPayload['sdp'],
        offerPayload['type'],
      );
      
      await _peerConnection!.setRemoteDescription(description);
      
      final RTCSessionDescription answer = await _peerConnection!.createAnswer();
      await _peerConnection!.setLocalDescription(answer);
      
      await _supabase.from('webrtc_signaling').insert({
        'session_id': sessionId,
        'type': 'answer_tablet',
        'payload': answer.toMap()
      });
    } catch (e) {
      debugPrint("CRITICAL: Error mapping Remote SDP Offer - $e");
    }
  }

  /// Appends parent ICE candidates to the local peer connection
  Future<void> _handleRemoteCandidate(Map<String, dynamic> candidatePayload) async {
    try {
      final candidate = RTCIceCandidate(
        candidatePayload['candidate'],
        candidatePayload['sdpMid'],
        candidatePayload['sdpMLineIndex'],
      );
      await _peerConnection!.addCandidate(candidate);
    } catch (e) {
      debugPrint("Error appending remote candidate: $e");
    }
  }

  void dispose() {
    _localStream?.getTracks().forEach((track) => track.stop());
    _localStream?.dispose();
    _peerConnection?.dispose();
    localRenderer.dispose();
  }
}
