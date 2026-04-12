import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:deepinheart/config/webrtc_config.dart';
import 'package:deepinheart/services/signaling_client.dart';

enum WebRTCConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
  failed,
}

class WebRTCService {
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  SignalingClient? _signalingClient;
  String? _roomId;
  String? _userId;
  String? _remoteUserId;
  
  final StreamController<MediaStream> _remoteStreamController = 
      StreamController<MediaStream>.broadcast();
  final StreamController<WebRTCConnectionState> _connectionStateController = 
      StreamController<WebRTCConnectionState>.broadcast();
  final StreamController<String> _errorController = 
      StreamController<String>.broadcast();

  // Event streams
  Stream<MediaStream> get remoteStream => _remoteStreamController.stream;
  Stream<WebRTCConnectionState> get connectionState => _connectionStateController.stream;
  Stream<String> get errorStream => _errorController.stream;

  // State getters
  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStreamSync => _remoteStream;
  WebRTCConnectionState get currentState => _currentState;
  WebRTCConnectionState _currentState = WebRTCConnectionState.disconnected;

  // Call type
  bool _isVideoCall = true;
  bool get isVideoCall => _isVideoCall;

  bool _isDisposed = false;

  void _safeAddConnectionState(WebRTCConnectionState state) {
    if (_isDisposed || _connectionStateController.isClosed) return;
    _currentState = state;
    _connectionStateController.add(state);
  }

  void _safeAddError(String error) {
    if (_isDisposed || _errorController.isClosed) return;
    _errorController.add(error);
  }

  Future<void> initialize({
    required BuildContext context,
    required bool isVideoCall,
    required String roomId,
    required String userId,
    required String signalingUrl,
  }) async {
    try {
      debugPrint('=== WebRTC Service Initialization ===');
      // Dispose any existing state before initializing
      await _resetState();
      
      _isVideoCall = isVideoCall;
      _roomId = roomId;
      _userId = userId;
      
      debugPrint('🎥 Initializing WebRTC service...');
      debugPrint('   - Room: $roomId');
      debugPrint('   - User ID: $userId');
      debugPrint('   - Video Call: $isVideoCall');
      debugPrint('   - Signaling URL: "$signalingUrl"');

      if (signalingUrl.trim().isEmpty) {
        throw Exception("WebRTC server URL is empty. Please configure it in the admin panel.");
      }

      // Clean up URL and ensure it's ws/wss if needed, or just use as is if the client handles it
      final cleanUrl = signalingUrl.trim().replaceAll(RegExp(r'/+$'), '');
      
      await _initializeSignalingClient(cleanUrl);
      await _createPeerConnection();
      await _getUserMedia();

      // Removed manual connected state - let onConnectionState handle it
      debugPrint('✅ WebRTC service local components initialized');
      
    } catch (e) {
      debugPrint('❌ Failed to initialize WebRTC service: $e');
      _safeAddError('Initialization failed: $e');
      _safeAddConnectionState(WebRTCConnectionState.failed);
      rethrow;
    }
  }

  Future<void> _initializeSignalingClient(String signalingUrl) async {
    debugPrint('🚀 Connecting to WebRTC signaling server: $signalingUrl');

    _signalingClient = SignalingClient();
    
    // Listen for signaling messages before connecting
    _signalingClient!.messageStream.listen(_handleSignalingMessage);
    
    bool joinAttempted = false;

    _signalingClient!.connectedStream.listen((_) {
      if (_roomId != null && !joinAttempted) {
        debugPrint('✅ Signaling connected event. Joining room: $_roomId');
        joinAttempted = true;
        _signalingClient!.joinRoom(_roomId!);
      }
    });
    
    await _signalingClient!.connect(signalingUrl, _userId!);
    
    // Safety check: if already connected after await and not yet attempted
    if (_signalingClient!.isConnected && _roomId != null && !joinAttempted) {
      debugPrint('✅ Signaling already connected. Joining room: $_roomId');
      joinAttempted = true;
      await _signalingClient!.joinRoom(_roomId!);
    }
  }

  Future<void> _resetState() async {
    debugPrint('🧹 Resetting WebRTC service state...');
    
    // Close peer connection
    if (_peerConnection != null) {
      await _peerConnection!.close();
      _peerConnection = null;
    }

    // Stop local stream
    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        track.stop();
      }
      await _localStream!.dispose();
      _localStream = null;
    }

    // Disconnect signaling client
    if (_signalingClient != null) {
      _signalingClient!.disconnect();
      _signalingClient!.dispose();
      _signalingClient = null;
    }

    // Clear state
    _remoteStream = null;
    _remoteUserId = null;
    _roomId = null;
    _userId = null;
    _currentState = WebRTCConnectionState.disconnected;
    
    debugPrint('✅ WebRTC service state reset');
  }

  List<RTCIceCandidate> _remoteIceCandidatesQueue = [];

  Future<void> _createPeerConnection() async {
    final config = WebRTCConfig.getPeerConnectionConfig(null);
    config['sdpSemantics'] = 'unified-plan';

    _peerConnection = await createPeerConnection(config);
    
    // Add event listeners
    _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
      if (_remoteUserId != null) {
        _signalingClient!.sendIceCandidate(
          _remoteUserId!,
          candidate.toMap(),
        );
      } else {
        debugPrint('⚠️ ICE candidate generated but _remoteUserId is null, candidate might be lost');
      }
    };

    _peerConnection!.onConnectionState = (RTCPeerConnectionState state) {
      if (_isDisposed) return;
      debugPrint('🔗 Connection state: ${state.name}');
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _safeAddConnectionState(WebRTCConnectionState.connected);
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _safeAddConnectionState(WebRTCConnectionState.failed);
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
          _safeAddConnectionState(WebRTCConnectionState.connecting);
          break;
        default:
          break;
      }
    };

    _peerConnection!.onTrack = (RTCTrackEvent event) {
      if (_isDisposed) return;
      debugPrint('📹 Remote track added: ${event.track.kind}');
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        if (!_remoteStreamController.isClosed) {
          _remoteStreamController.add(_remoteStream!);
        }
      }
    };

    _peerConnection!.onRemoveTrack = (MediaStream stream, MediaStreamTrack track) {
      debugPrint('📹 Remote track removed: ${track.kind}');
    };

    debugPrint('✅ Peer connection created');
  }

  Future<void> _getUserMedia() async {
    try {
      final constraints = _isVideoCall 
          ? WebRTCConfig.videoConstraints 
          : WebRTCConfig.audioConstraints;

      _localStream = await navigator.mediaDevices.getUserMedia(constraints);
      
      // Add local tracks to peer connection
      _localStream!.getTracks().forEach((track) {
        _peerConnection!.addTrack(track, _localStream!);
      });
      
      debugPrint('✅ Local media tracks added to peer connection');
      
    } catch (e) {
      debugPrint('❌ Failed to get user media: $e');
      _errorController.add('Failed to access camera/microphone: $e');
      rethrow;
    }
  }

  Future<void> _handleSignalingMessage(SignalingMessage message) async {
    debugPrint('📨 Handling signaling message: ${message.type.name}');
    
    switch (message.type) {
      case SignalingEventType.userJoined:
        _remoteUserId = message.from;
        await _createAndSendOffer();
        break;
        
      case SignalingEventType.offer:
        _remoteUserId = message.from;
        await _handleOffer(message.data);
        break;
        
      case SignalingEventType.answer:
        await _handleAnswer(message.data);
        break;
        
      case SignalingEventType.iceCandidate:
        await _handleIceCandidate(message.data);
        break;
        
      case SignalingEventType.userLeft:
        _remoteUserId = null;
        _connectionStateController.add(WebRTCConnectionState.disconnected);
        _currentState = WebRTCConnectionState.disconnected;
        break;
        
      default:
        debugPrint('⚠️ Unhandled message type: ${message.type.name}');
    }
  }

  Future<void> _createAndSendOffer() async {
    if (_peerConnection == null || _remoteUserId == null) return;

    try {
      final RTCSessionDescription offer = 
          await _peerConnection!.createOffer();
      await _peerConnection!.setLocalDescription(offer);
      
      await _signalingClient!.sendOffer(_remoteUserId!, offer.toMap());
      debugPrint('📤 Offer created and sent');
      
    } catch (e) {
      debugPrint('❌ Failed to create offer: $e');
      _errorController.add('Failed to create offer: $e');
    }
  }

  Future<void> _handleOffer(Map<String, dynamic> offerData) async {
    if (_peerConnection == null) return;

    try {
      final offer = RTCSessionDescription(offerData['sdp'], 'offer');
      await _peerConnection!.setRemoteDescription(offer);
      
      // Process queued candidates
      for (var candidate in _remoteIceCandidatesQueue) {
        await _peerConnection!.addCandidate(candidate);
      }
      _remoteIceCandidatesQueue.clear();

      // Create and send answer
      final answer = await _peerConnection!.createAnswer();
      await _peerConnection!.setLocalDescription(answer);
      
      if (_remoteUserId != null) {
        await _signalingClient!.sendAnswer(_remoteUserId!, answer.toMap());
      }
      
      debugPrint('📨 Offer handled and answer sent');
      
    } catch (e) {
      debugPrint('❌ Failed to handle offer: $e');
      _errorController.add('Failed to handle offer: $e');
    }
  }

  Future<void> _handleAnswer(Map<String, dynamic> answerData) async {
    if (_peerConnection == null) return;

    try {
      final answer = RTCSessionDescription(answerData['sdp'], 'answer');
      await _peerConnection!.setRemoteDescription(answer);
      
      // Process queued candidates
      for (var candidate in _remoteIceCandidatesQueue) {
        await _peerConnection!.addCandidate(candidate);
      }
      _remoteIceCandidatesQueue.clear();
      
      debugPrint('📨 Answer handled');
      
    } catch (e) {
      debugPrint('❌ Failed to handle answer: $e');
      _errorController.add('Failed to handle answer: $e');
    }
  }

  Future<void> _handleIceCandidate(Map<String, dynamic> candidateData) async {
    if (_peerConnection == null) return;

    try {
      final candidate = RTCIceCandidate(
        candidateData['candidate'],
        candidateData['sdpMid'],
        candidateData['sdpMLineIndex'],
      );
      
      if (_peerConnection!.getRemoteDescription() != null) {
        await _peerConnection!.addCandidate(candidate);
        debugPrint('📨 ICE candidate added immediately');
      } else {
        _remoteIceCandidatesQueue.add(candidate);
        debugPrint('📨 ICE candidate queued (remote description not set yet)');
      }
      
    } catch (e) {
      debugPrint('❌ Failed to add ICE candidate: $e');
      _safeAddError('Failed to add ICE candidate: $e');
    }
  }

  // Media controls
  Future<void> toggleMicrophone() async {
    if (_localStream == null || _isDisposed) return;

    final audioTrack = _localStream!.getAudioTracks().first;
    audioTrack.enabled = !audioTrack.enabled;
    debugPrint('🎤 Microphone ${audioTrack.enabled ? 'enabled' : 'disabled'}');
  }

  Future<void> toggleCamera() async {
    if (_localStream == null || !_isVideoCall) return;

    final videoTrack = _localStream!.getVideoTracks().first;
    videoTrack.enabled = !videoTrack.enabled;
    debugPrint('📹 Camera ${videoTrack.enabled ? 'enabled' : 'disabled'}');
  }

  Future<void> switchCamera() async {
    if (_localStream == null || !_isVideoCall) return;

    try {
      final videoTrack = _localStream!.getVideoTracks().first;
      await Helper.switchCamera(videoTrack);
      debugPrint('📹 Camera switched');
    } catch (e) {
      debugPrint('❌ Failed to switch camera: $e');
      _errorController.add('Failed to switch camera: $e');
    }
  }

  bool get isMicrophoneEnabled {
    if (_localStream == null) return false;
    final audioTrack = _localStream!.getAudioTracks().first;
    return audioTrack.enabled;
  }

  bool get isCameraEnabled {
    if (_localStream == null || !_isVideoCall) return false;
    final videoTrack = _localStream!.getVideoTracks().first;
    return videoTrack.enabled;
  }

  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    
    debugPrint('🗑️ Disposing WebRTC service...');

    _safeAddConnectionState(WebRTCConnectionState.disconnected);
    
    // Stop local stream
    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        track.stop();
      }
      await _localStream!.dispose();
      _localStream = null;
    }

    // Close peer connection
    if (_peerConnection != null) {
      await _peerConnection!.close();
      _peerConnection = null;
    }

    // Disconnect signaling client
    if (_signalingClient != null) {
      _signalingClient!.disconnect();
      _signalingClient!.dispose();
      _signalingClient = null;
    }

    // Clear remote stream
    _remoteStream = null;
    _remoteUserId = null;
    _roomId = null;
    _userId = null;

    // Close stream controllers
    if (!_remoteStreamController.isClosed) await _remoteStreamController.close();
    if (!_connectionStateController.isClosed) await _connectionStateController.close();
    if (!_errorController.isClosed) await _errorController.close();

    debugPrint('✅ WebRTC service disposed');
  }
}
