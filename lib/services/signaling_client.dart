import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:deepinheart/config/webrtc_config.dart';

enum SignalingEventType {
  join,
  leave,
  offer,
  answer,
  iceCandidate,
  userJoined,
  userLeft,
  error,
}

class SignalingMessage {
  final SignalingEventType type;
  final Map<String, dynamic> data;
  final String? from;
  final String? to;
  final String room;

  SignalingMessage({
    required this.type,
    required this.data,
    required this.room,
    this.from,
    this.to,
  });

  Map<String, dynamic> toJson() {
    return {
      'type': type.name,
      'data': data,
      'room': room,
      'from': from,
      'to': to,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
  }

  factory SignalingMessage.fromJson(Map<String, dynamic> json) {
    return SignalingMessage(
      type: SignalingEventType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => SignalingEventType.error,
      ),
      data: json['data'] ?? {},
      room: json['room'] ?? '',
      from: json['from']?.toString() ?? json['userId']?.toString(),
      to: json['to']?.toString(),
    );
  }
}

class SignalingClient {
  IO.Socket? _socket;
  String? _currentRoom;
  String? _userId;
  final StreamController<SignalingMessage> _messageController = 
      StreamController<SignalingMessage>.broadcast();
  
  // Event streams
  Stream<SignalingMessage> get messageStream => _messageController.stream;
  Stream<void> get connectedStream => _connectedController.stream;
  Stream<void> get disconnectedStream => _disconnectedController.stream;
  Stream<String> get errorStream => _errorController.stream;
  
  final StreamController<void> _connectedController = 
      StreamController<void>.broadcast();
  final StreamController<void> _disconnectedController = 
      StreamController<void>.broadcast();
  final StreamController<String> _errorController = 
      StreamController<String>.broadcast();

  bool get isConnected => _socket?.connected ?? false;
  String? get currentRoom => _currentRoom;
  String? get userId => _userId;

  Future<void> connect(String signalingUrl, String userId) async {
    try {
      _userId = userId;
      
      debugPrint('[SIG] 🔌 Connecting to signaling server: $signalingUrl');

      // Convert ws:// to http:// if needed for better socket.io compatibility
      String url = signalingUrl;
      if (url.startsWith('ws://')) {
        url = url.replaceFirst('ws://', 'http://');
      } else if (url.startsWith('wss://')) {
        url = url.replaceFirst('wss://', 'https://');
      }
      
      debugPrint('[SIG] 🔌 Attempting connection to: $url with transports: [\'websocket\']');

      _socket = IO.io(
        url,
        IO.OptionBuilder()
            .setTransports(['websocket'])
            .enableAutoConnect()
            .setReconnectionAttempts(WebRTCConfig.maxReconnectionAttempts)
            .setReconnectionDelay(WebRTCConfig.reconnectionDelay.inMilliseconds)
            .setTimeout(WebRTCConfig.connectionTimeout.inMilliseconds)
            .build(),
      );

      _setupEventListeners();

      _socket?.connect();
      
      debugPrint('[SIG] ⏳ Waiting for socket connection...');
      // Wait for connection with timeout
      int attempts = 0;
      while (!isConnected && attempts < 50) { // 10 seconds total
        await Future.delayed(const Duration(milliseconds: 200));
        if (attempts % 10 == 0) {
          debugPrint('[SIG]   ...still waiting (${attempts * 0.2}s), connected: $isConnected');
        }
        attempts++;
      }

      if (isConnected) {
        debugPrint('[SIG] ✅ Connected to signaling server');
        _connectedController.add(null);
      } else {
        debugPrint('[SIG] ⚠️ Connection timeout, but proceeding...');
      }
      
    } catch (e) {
      debugPrint('[SIG] ❌ Failed to connect to signaling server: $e');
      _errorController.add('Connection failed: $e');
    }
  }

  void _setupEventListeners() {
    if (_socket == null) return;

    // Raw event logger for debugging
    _socket!.onAny((event, data) {
      debugPrint('[SIG] [RAW EVENT] $event: $data');
    });

    _socket!.onConnect((_) {
      debugPrint('[SIG] ✅ Socket connected successfully! ID: ${_socket?.id}');
      _connectedController.add(null);
    });

    _socket!.onDisconnect((reason) {
      debugPrint('[SIG] ❌ Socket disconnected. Reason: $reason');
      _disconnectedController.add(null);
    });

    _socket!.onConnectError((error) {
      debugPrint('[SIG] ❌ Socket connection error detail: $error');
      _errorController.add('Connection error: $error');
    });

    _socket!.on('connect_timeout', (data) {
      debugPrint('[SIG] ❌ Socket connection timeout: $data');
    });

    _socket!.onError((error) {
      debugPrint('[SIG] ❌ Socket error: $error');
      _errorController.add('Socket error: $error');
    });

    _socket!.on('message', (data) {
      try {
        final message = SignalingMessage.fromJson(data);
        debugPrint('[SIG] 📨 Received message from ${message.from}: ${message.type.name}');
        _messageController.add(message);
      } catch (e) {
        debugPrint('[SIG] ❌ Failed to parse message: $e');
      }
    });

    _socket!.on('room-joined', (data) {
      debugPrint('[SIG] 🏠 Room joined successfully: ${data['room']}');
    });

    _socket!.on('user-joined', (data) {
      debugPrint('[SIG] 👤 Remote user joined: ${data['userId']}');
      final message = SignalingMessage(
        type: SignalingEventType.userJoined,
        data: data,
        room: _currentRoom ?? '',
        from: data['userId']?.toString(),
      );
      _messageController.add(message);
    });

    _socket!.on('user-left', (data) {
      debugPrint('[SIG] 👋 User left room: ${data['userId']}');
      final message = SignalingMessage(
        type: SignalingEventType.userLeft,
        data: data,
        room: _currentRoom ?? '',
        from: data['userId']?.toString(),
      );
      _messageController.add(message);
    });
  }

  Future<void> joinRoom(String roomId) async {
    if (!isConnected) {
      throw Exception('Not connected to signaling server');
    }

    _currentRoom = roomId;
    
    // Server expects exactly { room: string, userId: string }
    final joinData = {
      'room': roomId,
      'userId': _userId?.toString(),
    };

    _socket?.emit('join-room', joinData);
    debugPrint('🏠 Joining room: $roomId with userId: $_userId');
  }

  Future<void> leaveRoom() async {
    if (!isConnected || _currentRoom == null) return;

    final leaveData = {
      'room': _currentRoom,
      'userId': _userId?.toString(),
    };

    _socket?.emit('leave-room', leaveData);
    debugPrint('🚪 Leaving room: $_currentRoom');
    
    _currentRoom = null;
  }

  Future<void> sendOffer(String targetUserId, Map<String, dynamic> offer) async {
    if (!isConnected || _currentRoom == null) {
      throw Exception('Not connected to room');
    }

    final messageData = {
      'type': SignalingEventType.offer.name,
      'data': offer,
      'room': _currentRoom!,
      'from': _userId,
      'to': targetUserId.toString(),
    };

    _socket?.emit('send-message', messageData);
    debugPrint('📤 Sending offer to: $targetUserId');
  }

  Future<void> sendAnswer(String targetUserId, Map<String, dynamic> answer) async {
    if (!isConnected || _currentRoom == null) {
      throw Exception('Not connected to room');
    }

    final messageData = {
      'type': SignalingEventType.answer.name,
      'data': answer,
      'room': _currentRoom!,
      'from': _userId,
      'to': targetUserId.toString(),
    };

    _socket?.emit('send-message', messageData);
    debugPrint('📤 Sending answer to: $targetUserId');
  }

  Future<void> sendIceCandidate(String targetUserId, Map<String, dynamic> candidate) async {
    if (!isConnected || _currentRoom == null) {
      throw Exception('Not connected to room');
    }

    final messageData = {
      'type': SignalingEventType.iceCandidate.name,
      'data': candidate,
      'room': _currentRoom!,
      'from': _userId,
      'to': targetUserId.toString(),
    };

    _socket?.emit('send-message', messageData);
    debugPrint('📤 Sending ICE candidate to: $targetUserId');
  }

  void disconnect() {
    if (_currentRoom != null) {
      leaveRoom();
    }

    _socket?.disconnect();
    _socket = null;
    _currentRoom = null;
    _userId = null;
    
    debugPrint('🔌 Disconnected from signaling server');
  }

  void dispose() {
    disconnect();
    _messageController.close();
    _connectedController.close();
    _disconnectedController.close();
    _errorController.close();
  }
}
