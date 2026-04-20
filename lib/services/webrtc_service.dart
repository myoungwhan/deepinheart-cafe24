import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:deepinheart/config/webrtc_config.dart';
import 'package:deepinheart/services/signaling_client.dart';

enum ConnectionType {
  direct,      // P2P direct connection
  relay,       // TURN relay connection
  failed,      // Connection failed
}

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
  final StreamController<ConnectionType> _connectionTypeController = 
      StreamController<ConnectionType>.broadcast();

  // Event streams
  Stream<MediaStream> get remoteStream => _remoteStreamController.stream;
  Stream<WebRTCConnectionState> get connectionState => _connectionStateController.stream;
  Stream<String> get errorStream => _errorController.stream;
  Stream<ConnectionType> get connectionType => _connectionTypeController.stream;

  // State getters
  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStreamSync => _remoteStream;
  WebRTCConnectionState get currentState => _currentState;
  WebRTCConnectionState _currentState = WebRTCConnectionState.disconnected;
  ConnectionType _currentConnectionType = ConnectionType.failed;
  ConnectionType get currentConnectionType => _currentConnectionType;

  // Call type
  bool _isVideoCall = true;
  bool get isVideoCall => _isVideoCall;
  bool _isMobileNetwork = false;

  bool _isDisposed = false;

  void _safeAddRemoteStream(MediaStream stream) {
    if (_isDisposed || _remoteStreamController.isClosed) return;
    _remoteStreamController.add(stream);
  }

  void _safeAddConnectionState(WebRTCConnectionState state) {
    if (_isDisposed || _connectionStateController.isClosed) return;
    _currentState = state;
    _connectionStateController.add(state);
  }

  void _safeAddError(String error) {
    if (_isDisposed || _errorController.isClosed) return;
    _errorController.add(error);
  }

  void _safeAddConnectionType(ConnectionType type) {
    if (_isDisposed || _connectionTypeController.isClosed) return;
    _currentConnectionType = type;
    _connectionTypeController.add(type);
  }

  // Network detection
  Future<bool> _detectNetworkType() async {
    try {
      final connectivityResult = await InternetAddress.lookup('8.8.8.8');
      if (connectivityResult.isNotEmpty) {
        final address = connectivityResult[0].address;
        _isMobileNetwork = address.startsWith('10.') || 
                          address.startsWith('192.168.') ||
                          address.startsWith('172.') ||
                          address.startsWith('169.254.');
      }
      return true;
    } catch (e) {
      debugPrint('Network detection failed: $e');
      return false;
    }
  }

  void _detectConnectionType(RTCPeerConnectionState state) {
    switch (state) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        _checkIfUsingRelay();
        break;
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        _safeAddConnectionType(ConnectionType.failed);
        break;
      default:
        break;
    }
  }

  Future<void> _checkIfUsingRelay() async {
    try {
      final stats = await _peerConnection?.getStats();
      bool isRelay = false;
      
      if (stats != null) {
        for (var report in stats) {
          if (report.type == 'candidate-pair' && report.values['state'] == 'succeeded') {
            final localCandidateId = report.values['localCandidateId'] as String?;
            if (localCandidateId != null) {
              final localCandidate = stats.firstWhere(
                (element) => element.id == localCandidateId,
                orElse: () => report,
              );
              if (localCandidate.values['candidateType'] == 'relay') {
                isRelay = true;
                break;
              }
            }
          }
        }
      }
      
      _safeAddConnectionType(isRelay ? ConnectionType.relay : ConnectionType.direct);
      debugPrint('Connection type: ${isRelay ? "RELAY (TURN)" : "DIRECT (P2P)"}');
      
    } catch (e) {
      debugPrint('Failed to detect connection type: $e');
      _safeAddConnectionType(ConnectionType.direct);
    }
  }

  Future<void> initialize({
    required BuildContext context,
    required bool isVideoCall,
    required String roomId,
    required String userId,
    required String signalingUrl,
    String? turnConfig,
  }) async {
    try {
      debugPrint('=== WebRTC Service Initialization ===');
      await _resetState();
      _isDisposed = false; // Reset disposal state
      
      _isVideoCall = isVideoCall;
      _roomId = roomId;
      _userId = userId;
      
      await _detectNetworkType();
      
      if (signalingUrl.trim().isEmpty) {
        throw Exception("WebRTC server URL is empty.");
      }

      final cleanUrl = signalingUrl.trim().replaceAll(RegExp(r'/+$'), '');
      
      await _initializeSignalingClient(cleanUrl);
      await _createPeerConnection(turnConfig);
      await _getUserMedia();

      debugPrint('WebRTC service local components initialized');
    } catch (e) {
      debugPrint('Failed to initialize WebRTC service: $e');
      _safeAddError('Initialization failed: $e');
      _safeAddConnectionState(WebRTCConnectionState.failed);
      rethrow;
    }
  }

  Future<void> _initializeSignalingClient(String signalingUrl) async {
    _signalingClient = SignalingClient();
    _signalingClient!.messageStream.listen(_handleSignalingMessage);
    
    bool joinAttempted = false;
    _signalingClient!.connectedStream.listen((_) {
      if (_roomId != null && !joinAttempted) {
        joinAttempted = true;
        _signalingClient!.joinRoom(_roomId!);
      }
    });
    
    await _signalingClient!.connect(signalingUrl, _userId!);
  }

  Future<void> _resetState() async {
    if (_peerConnection != null) {
      await _peerConnection!.close();
      _peerConnection = null;
    }
    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) track.stop();
      await _localStream!.dispose();
      _localStream = null;
    }
    if (_signalingClient != null) {
      _signalingClient!.disconnect();
      _signalingClient!.dispose();
      _signalingClient = null;
    }
    _remoteStream = null;
    _remoteUserId = null;
    _currentState = WebRTCConnectionState.disconnected;
  }

  final List<RTCIceCandidate> _remoteIceCandidatesQueue = [];
  final List<RTCIceCandidate> _localIceCandidatesQueue = [];

  Future<void> _createPeerConnection(String? turnConfig) async {
    final config = WebRTCConfig.getOptimalConfig(turnConfig, _isMobileNetwork);
    config['sdpSemantics'] = 'unified-plan';

    _peerConnection = await createPeerConnection(config);
    
    _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
      if (_remoteUserId != null) {
        debugPrint('WebRTC: Sending ICE Candidate to $_remoteUserId');
        _signalingClient!.sendIceCandidate(_remoteUserId!, candidate.toMap());
      } else {
        debugPrint('WebRTC: Queuing local ICE Candidate');
        _localIceCandidatesQueue.add(candidate);
      }
    };

    _peerConnection!.onConnectionState = (RTCPeerConnectionState state) {
      if (_isDisposed) return;
      debugPrint('WebRTC: Connection State Changed -> ${state.toString()}');
      _detectConnectionType(state);
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
      debugPrint('WebRTC: Received Remote Track: ${event.track.kind}');
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        _safeAddRemoteStream(_remoteStream!);
        
        // تحسين: ضبط وضع الصوت فور استقبال المسار
        if (event.track.kind == 'audio') {
          debugPrint('📞 Remote audio stream received and active');
          // Important: Default to speaker for video calls and earpiece for voice calls
          toggleSpeaker(_isVideoCall);
        }
      }
    };
    
    // إشعار عند الحاجة لإعادة التفاوض (مهم جداً لاستقرار الاتصال)
    _peerConnection!.onRenegotiationNeeded = () async {
      if (_remoteUserId != null && _shouldInitiateOffer()) {
        debugPrint('WebRTC: Renegotiation needed, creating offer...');
        await _createAndSendOffer();
      }
    };

    debugPrint('✅ Peer connection created');
  }

  Future<void> _getUserMedia() async {
    final constraints = _isVideoCall ? WebRTCConfig.videoConstraints : WebRTCConfig.audioConstraints;
    _localStream = await navigator.mediaDevices.getUserMedia(constraints);
    
    if (_peerConnection == null) return;

    for (var track in _localStream!.getTracks()) {
      await _peerConnection!.addTrack(track, _localStream!);
    }
    
    debugPrint('✅ Local stream added to PeerConnection');

    // إذا كان الطرف الآخر موجوداً بالفعل ونحن من يجب أن يبدأ المكالمة
    if (_remoteUserId != null && _shouldInitiateOffer()) {
      debugPrint('WebRTC: Remote user was waiting, sending offer now');
      await _createAndSendOffer();
      _flushLocalIceCandidates();
    }
  }

  // قاعدة لفض الاشتباك: المستخدم صاحب المعرف الأكبر (أبجدياً) هو من يرسل الـ Offer
  bool _shouldInitiateOffer() {
    if (_userId == null || _remoteUserId == null) return false;
    return _userId!.compareTo(_remoteUserId!) > 0;
  }

  Future<void> _handleSignalingMessage(SignalingMessage message) async {
    switch (message.type) {
      case SignalingEventType.userJoined:
        debugPrint('WebRTC: User joined event from: ${message.from}');
        _remoteUserId = message.from;
        
        // تحديث الحالة إلى جاري الاتصال
        _safeAddConnectionState(WebRTCConnectionState.connecting);

        if (_localStream != null) {
          if (_shouldInitiateOffer()) {
            debugPrint('WebRTC: Initiating offer to ${_remoteUserId}');
            await _createAndSendOffer();
            _flushLocalIceCandidates();
          } else {
            debugPrint('WebRTC: Waiting for offer from ${_remoteUserId} (polite peer)');
            // بدء مؤقت الأمان: إذا لم يرسل الطرف الآخر Offer، سنقوم نحن بذلك
            _startOfferTimeoutTimer();
          }
        } else {
          debugPrint('WebRTC: Local stream not ready yet, will check after getUserMedia');
        }
        break;
      case SignalingEventType.offer:
        debugPrint('WebRTC: Received offer from: ${message.from}');
        _remoteUserId = message.from;
        await _handleOffer(message.data);
        _flushLocalIceCandidates();
        break;
      case SignalingEventType.answer:
        debugPrint('WebRTC: Received answer from: ${message.from}');
        await _handleAnswer(message.data);
        break;
      case SignalingEventType.iceCandidate:
        await _handleIceCandidate(message.data);
        break;
      case SignalingEventType.userLeft:
        debugPrint('WebRTC: User left: ${message.from}');
        _remoteUserId = null;
        _safeAddConnectionState(WebRTCConnectionState.disconnected);
        break;
      default:
        break;
    }
  }

  Future<void> _createAndSendOffer() async {
    if (_peerConnection == null || _remoteUserId == null) return;
    final RTCSessionDescription offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);
    await _signalingClient!.sendOffer(_remoteUserId!, offer.toMap());
  }

  Future<void> _handleOffer(Map<String, dynamic> offerData) async {
    if (_peerConnection == null) return;
    debugPrint('WebRTC: Handling Offer, setting remote description...');
    final offer = RTCSessionDescription(offerData['sdp'], 'offer');
    await _peerConnection!.setRemoteDescription(offer);
    
    debugPrint('WebRTC: Creating answer...');
    final answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);
    
    if (_remoteUserId != null) {
      await _signalingClient!.sendAnswer(_remoteUserId!, answer.toMap());
    }

    // معالجة الـ ICE Candidates المخزنة بعد تعيين الوصف
    for (var candidate in _remoteIceCandidatesQueue) {
      await _peerConnection!.addCandidate(candidate);
    }
    _remoteIceCandidatesQueue.clear();
  }

  Future<void> _handleAnswer(Map<String, dynamic> answerData) async {
    if (_peerConnection == null) return;
    debugPrint('WebRTC: Handling Answer, setting remote description...');
    final answer = RTCSessionDescription(answerData['sdp'], 'answer');
    await _peerConnection!.setRemoteDescription(answer);
    
    // تحسين الجودة: ضبط Bitrate بعد اكتمال الاتصال
    _optimizeVideoQuality();
    
    // معالجة الـ ICE Candidates المخزنة بعد تعيين الوصف
    for (var candidate in _remoteIceCandidatesQueue) {
      await _peerConnection!.addCandidate(candidate);
    }
    _remoteIceCandidatesQueue.clear();
  }

  void _optimizeVideoQuality() async {
    if (_peerConnection == null) return;
    
    // الانتظار قليلاً لضمان استقرار المسارات
    await Future.delayed(const Duration(seconds: 2));
    
    final senders = await _peerConnection!.getSenders();
    for (var sender in senders) {
      if (sender.track?.kind == 'video') {
        final parameters = sender.parameters;
        final encodings = parameters.encodings;
        if (encodings != null && encodings.isNotEmpty) {
          for (var encoding in encodings) {
            encoding.maxBitrate = 1500000; // 1.5 Mbps
            encoding.minBitrate = 500000;  // 500 kbps
          }
          await sender.setParameters(parameters);
          debugPrint('🚀 WebRTC: Video Bitrate Optimized to 1.5Mbps');
        }
      }
    }
  }

  Future<void> _handleIceCandidate(Map<String, dynamic> candidateData) async {
    if (_peerConnection == null) return;
    
    final candidate = RTCIceCandidate(
      candidateData['candidate'],
      candidateData['sdpMid'],
      candidateData['sdpMLineIndex'],
    );

    final remoteDesc = await _peerConnection!.getRemoteDescription();
    if (remoteDesc != null) {
      debugPrint('WebRTC: Adding remote ICE candidate');
      await _peerConnection!.addCandidate(candidate);
    } else {
      debugPrint('WebRTC: Queuing remote ICE candidate (remote description not set)');
      _remoteIceCandidatesQueue.add(candidate);
    }
  }

  // ميزة جديدة: إعادة المحاولة إذا تأخر الـ Offer من الطرف الآخر
  void _startOfferTimeoutTimer() {
    Timer(const Duration(seconds: 5), () async {
      if (_isDisposed || _remoteUserId == null) return;
      
      final remoteDesc = await _peerConnection?.getRemoteDescription();
      if (remoteDesc == null) {
        debugPrint('WebRTC: Offer timeout (5s), taking initiative to start connection...');
        await _createAndSendOffer();
        _flushLocalIceCandidates();
      }
    });
  }

  void toggleSpeaker(bool speakerOn) {
    Helper.setSpeakerphoneOn(speakerOn);
  }

  Future<void> toggleMicrophone() async {
    if (_localStream == null) return;
    final audioTrack = _localStream!.getAudioTracks().first;
    audioTrack.enabled = !audioTrack.enabled;
  }

  Future<void> toggleCamera() async {
    if (_localStream == null || !_isVideoCall) return;
    final videoTrack = _localStream!.getVideoTracks().first;
    videoTrack.enabled = !videoTrack.enabled;
  }

  Future<void> switchCamera() async {
    if (_localStream != null && _isVideoCall) {
      final videoTracks = _localStream!.getVideoTracks();
      if (videoTracks.isNotEmpty) await Helper.switchCamera(videoTracks.first);
    }
  }

  void _flushLocalIceCandidates() {
    if (_peerConnection == null || _remoteUserId == null) return;
    for (var candidate in _localIceCandidatesQueue) {
      _signalingClient!.sendIceCandidate(_remoteUserId!, candidate.toMap());
    }
    _localIceCandidatesQueue.clear();
  }

  bool get isMicrophoneEnabled {
    if (_localStream == null) return false;
    return _localStream!.getAudioTracks().first.enabled;
  }

  bool get isCameraEnabled {
    if (_localStream == null || !_isVideoCall) return false;
    return _localStream!.getVideoTracks().first.enabled;
  }

  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    _safeAddConnectionState(WebRTCConnectionState.disconnected);
    await _resetState();
    if (!_remoteStreamController.isClosed) await _remoteStreamController.close();
    if (!_connectionStateController.isClosed) await _connectionStateController.close();
    if (!_errorController.isClosed) await _errorController.close();
    if (!_connectionTypeController.isClosed) await _connectionTypeController.close();
  }
}
