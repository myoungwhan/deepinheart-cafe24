import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:deepinheart/services/webrtc_service.dart';
import 'package:deepinheart/services/call_state_manager.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:deepinheart/screens/calls/widgets/coin_balance_widget.dart';
import 'package:deepinheart/screens/calls/widgets/call_rating_dialog.dart';
import 'package:deepinheart/Controller/Viewmodel/userviewmodel.dart';
import 'package:deepinheart/Controller/Viewmodel/setting_provider.dart';
import 'package:deepinheart/config/webrtc_config.dart';
import 'package:deepinheart/config/api_endpoints.dart';
import 'package:deepinheart/views/colors.dart';
import 'package:deepinheart/views/custom_text.dart';
import 'package:deepinheart/views/font_constants.dart';
import 'package:deepinheart/views/ui_helpers.dart';

class WebRTCVoiceCallScreen extends StatefulWidget {
  final String counselorName;
  final String channelName;
  final int userId;
  final double counselorRate;
  final int? appointmentId;
  final int? counselorId;
  final String? counselorImage;
  final bool isCounselor;
  final bool isTroat;

  const WebRTCVoiceCallScreen({
    Key? key,
    required this.counselorName,
    required this.channelName,
    required this.userId,
    this.counselorRate = 50.0,
    this.appointmentId,
    this.counselorId,
    this.counselorImage,
    required this.isCounselor,
    required this.isTroat,
  }) : super(key: key);

  @override
  State<WebRTCVoiceCallScreen> createState() => _WebRTCVoiceCallScreenState();
}

class _WebRTCVoiceCallScreenState extends State<WebRTCVoiceCallScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  WebRTCService? _webrtcService;

  bool _isLoading = true;
  bool _isConnected = false;
  bool _isMicrophoneEnabled = true;
  bool _isSpeakerEnabled = false;

  Timer? _callTimer;
  Timer? _coinDeductionTimer;
  Timer? _coinUpdateApiTimer;
  Duration _callDuration = Duration.zero;

  double _coinsLeft = 0.0;
  int _initialCoins = 0;
  int _estimatedMinutesLeft = 0;
  late double _coinsPerMinute;
  late double _coinsPerSecond;

  static const int LOW_COINS_THRESHOLD = 100;
  bool _lowCoinsWarningShown = false;
  bool _lessMinuteWarningShown = false;
  bool _isInitialized = false;

  String _appointmentType = "";

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _coinsPerMinute = widget.counselorRate;
    _coinsPerSecond = _coinsPerMinute / 60.0;

    _initAnimations();
    _initializeCall();
  }

  void _initAnimations() {
    _pulseController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.2).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _pulseController.repeat(reverse: true);
  }

  Future<void> _initializeCall() async {
    try {
      setState(() {
        _isLoading = true;
      });

      // Fetch appointment type first
      await fetchAppointmentType();

      // Load user coins
      await _loadUserCoins();

      // Check if user has enough coins (only for regular users and consult_now type)
      if (!widget.isCounselor && _appointmentType == 'consult_now' && _coinsLeft < _coinsPerMinute) {
        setState(() {
          _isLoading = false;
        });
        _showInsufficientCoinsDialog();
        return;
      }

      // Initialize WebRTC service
      final roomId = widget.channelName;
      final userId = widget.userId.toString();
      
      _webrtcService = WebRTCService();
      
      // Listen to service events
      _webrtcService!.connectionState.listen(_onConnectionStateChanged);
      _webrtcService!.remoteStream.listen(_onRemoteStream);
      _webrtcService!.errorStream.listen(_onError);

      final settingsProvider = Provider.of<SettingProvider>(context, listen: false);
      final signalingUrl = settingsProvider.settings?.webrtcServerUrl ?? '';
      
      // Initialize WebRTC for voice call
      await _webrtcService!.initialize(
        context: context,
        isVideoCall: false,
        roomId: roomId,
        userId: userId,
        signalingUrl: signalingUrl,
      );

      setState(() {
        _isInitialized = true;
        _isLoading = false;
      });

    } catch (e) {
      debugPrint('❌ Failed to initialize WebRTC voice call: $e');
      _showErrorDialog('Failed to initialize call: $e');
    }
  }

  Future<void> _loadUserCoins() async {
    try {
      final userProvider = Provider.of<UserViewModel>(context, listen: false);
      if (!widget.isCounselor && userProvider.userModel != null) {
        final user = userProvider.userModel;
        if (user != null && user.data.coins != null) {
          setState(() {
            _coinsLeft = user.data.coins!.toDouble();
            _initialCoins = user.data.coins!;
            _estimatedMinutesLeft = (_coinsLeft / _coinsPerMinute).floor();
          });
        }
      } else if (widget.isCounselor) {
        setState(() {
          _coinsLeft = 0;
          _initialCoins = 0;
        });
      }
    } catch (e) {
      debugPrint('❌ Failed to load user coins: $e');
    }
  }

  Future<Map<String, dynamic>?> fetchAppointmentType() async {
    if (widget.appointmentId == null) return null;

    try {
      final userViewModel = Provider.of<UserViewModel>(context, listen: false);
      final token = userViewModel.userModel?.data.token;

      if (token == null || token.isEmpty) return null;

      final response = await http.get(
        Uri.parse('${ApiEndPoints.BASE_URL}appointment/${widget.appointmentId}'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true && data['data'] != null) {
          final appointmentData = data['data'];
          _appointmentType = appointmentData['type']?.toString() ?? '';
          debugPrint('📋 Fetched appointment type: $_appointmentType');
          return appointmentData;
        }
      }
      return null;
    } catch (e) {
      debugPrint('❌ Error fetching appointment type: $e');
      return null;
    }
  }

  Future<void> _sendStartTimeApi() async {
    if (!widget.isCounselor) {
      debugPrint('⏱️ Not a counselor - skipping start_time API');
      return;
    }
    if (_appointmentType != 'consult_now') {
      debugPrint('⏱️ Not consult_now type - skipping start_time API');
      return;
    }
    if (widget.appointmentId == null) {
      debugPrint('⏱️ No appointment ID - skipping start_time API');
      return;
    }

    try {
      final userViewModel = Provider.of<UserViewModel>(context, listen: false);
      final token = userViewModel.userModel?.data.token;

      if (token == null || token.isEmpty) {
        debugPrint('❌ Start time API: No token available');
        return;
      }

      final now = DateTime.now();
      final startTime =
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';

      debugPrint(
        '🕐 Sending start_time API for appointment: ${widget.appointmentId}',
      );
      debugPrint('   Start time: $startTime');

      final request = http.MultipartRequest(
        'POST',
        Uri.parse(ApiEndPoints.UPDATE_TIME),
      );

      request.headers['Authorization'] = 'Bearer $token';
      request.fields['appointment_id'] = widget.appointmentId.toString();
      request.fields['start_time'] = startTime;

      final response = await request.send();
      final responseBody = await response.stream.bytesToString();

      if (response.statusCode == 200) {
        debugPrint('✅ Start time API success: $responseBody');
      } else {
        debugPrint(
          '❌ Start time API failed: ${response.statusCode} - $responseBody',
        );
      }
    } catch (e) {
      debugPrint('❌ Error sending start_time API: $e');
    }
  }

  Future<void> _sendEndTimeApi() async {
    if (_appointmentType != 'consult_now') {
      debugPrint('⏱️ Not consult_now type - skipping end_time API');
      return;
    }
    if (widget.appointmentId == null) {
      debugPrint('⏱️ No appointment ID - skipping end_time API');
      return;
    }

    try {
      final userViewModel = Provider.of<UserViewModel>(context, listen: false);
      final token = userViewModel.userModel?.data.token;

      if (token == null || token.isEmpty) {
        debugPrint('❌ End time API: No token available');
        return;
      }

      final now = DateTime.now();

      // Format end_time with proper padding (HH:mm format)
      final endTime =
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';

      // Validate endTime is not empty
      if (endTime.isEmpty || endTime.length < 5) {
        debugPrint('❌ Invalid end_time format: "$endTime"');
        return;
      }

      // Calculate total coins deducted from the call
      final durationInMinutes = _callDuration.inSeconds / 60.0;
      final coinsBasedOnDuration =
          (durationInMinutes * _coinsPerMinute).toInt().toString();

      debugPrint('═══════════════════════════════════════');
      debugPrint('🕐 Sending end_time API');
      debugPrint('   Appointment ID: ${widget.appointmentId}');
      debugPrint('   End time: "$endTime"');
      debugPrint('   Coins deducted: $coinsBasedOnDuration');
      debugPrint('═══════════════════════════════════════');

      final request = http.MultipartRequest(
        'POST',
        Uri.parse(ApiEndPoints.UPDATE_TIME),
      );

      request.headers['Authorization'] = 'Bearer $token';
      request.fields['appointment_id'] = widget.appointmentId.toString();
      request.fields['end_time'] = endTime;
      request.fields['coins'] = coinsBasedOnDuration;

      final response = await request.send();
      final responseBody = await response.stream.bytesToString();

      if (response.statusCode == 200) {
        debugPrint('✅ End time API success: $responseBody');
      } else {
        debugPrint(
          '❌ End time API failed: ${response.statusCode} - $responseBody',
        );
      }
    } catch (e) {
      debugPrint('❌ Error sending end_time API: $e');
    }
  }

  Future<void> _completeAppointmentApi() async {
    if (widget.appointmentId == null || widget.counselorId == null) {
      debugPrint(
        '⚠️ Missing appointment_id or counselor_id for complete-appointment API',
      );
      return;
    }

    final appointmentData = await fetchAppointmentType();
    if (appointmentData == null) {
      return;
    }
    if (appointmentData['counselor_status'].toString().toLowerCase() ==
        'pending') {
      debugPrint('❌ Counselor is pending');
      return;
    }

    try {
      final userViewModel = Provider.of<UserViewModel>(context, listen: false);
      final token = userViewModel.userModel?.data.token;

      if (token == null || token.isEmpty) {
        debugPrint('❌ Complete appointment API: No token available');
        return;
      }

      debugPrint('═══════════════════════════════════════');
      debugPrint('📤 USER: Calling complete-appointment API...');
      debugPrint('   Appointment ID: ${widget.appointmentId}');
      debugPrint('   Counselor ID: ${widget.counselorId}');
      debugPrint('═══════════════════════════════════════');

      final response = await http.post(
        Uri.parse('${ApiEndPoints.BASE_URL}complete-appointment'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'appointment_id': widget.appointmentId,
          'counselor_id': widget.counselorId,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        debugPrint('✅ Complete appointment API success: ${data.toString()}');
      } else {
        debugPrint(
          '❌ Complete appointment API failed: ${response.statusCode} - ${response.body}',
        );
      }
    } catch (e) {
      debugPrint('❌ Error calling complete-appointment API: $e');
    }
  }

  void _onConnectionStateChanged(WebRTCConnectionState state) {
    debugPrint('WebRTC Connection state changed: $state');
    if (mounted) {
      setState(() {
        switch (state) {
          case WebRTCConnectionState.connected:
            _isConnected = true;
            _startCallTimer();

            if (widget.isCounselor) {
              if (_appointmentType == 'consult_now') {
                _sendStartTimeApi();
              }
            } else {
              if (_appointmentType == 'consult_now') {
                _startCoinDeduction();
                _startCoinUpdateApiTimer();
              }
            }
            break;
          case WebRTCConnectionState.connecting:
            _isConnected = false;
            break;
          case WebRTCConnectionState.disconnected:
          case WebRTCConnectionState.failed:
            _isConnected = false;
            _stopCallTimer();
            _stopCoinDeduction();
            _stopCoinUpdateApiTimer();
            _handleSessionEnded();
            break;
          default:
            _isConnected = false;
            break;
        }
      });
    }
  }

  void _onRemoteStream(MediaStream stream) {
    debugPrint('📞 Remote audio stream received');
  }

  void _onError(String error) {
    debugPrint('❌ WebRTC error: $error');
    if (mounted) {
      setState(() {
        _isLoading = false;
      });
      Get.snackbar(
        'Connection Error'.tr,
        'Failed to connect: $error'.tr,
        backgroundColor: Colors.red,
        colorText: Colors.white,
      );
    }
  }

  void _startCallTimer() {
    if (_callTimer == null || !_callTimer!.isActive) {
      debugPrint('⏱️ Starting call timer');
      _callTimer = Timer.periodic(Duration(seconds: 1), (timer) {
        if (mounted) {
          setState(() {
            _callDuration = Duration(seconds: _callDuration.inSeconds + 1);
          });
        }
      });
    }
  }

  void _stopCallTimer() {
    debugPrint('⏱️ Stopping call timer');
    _callTimer?.cancel();
    _callTimer = null;
  }

  void _startCoinDeduction() {
    if (widget.isCounselor) return;

    if (_coinDeductionTimer == null || !_coinDeductionTimer!.isActive) {
      debugPrint('💰 Starting coin deduction');
      _coinDeductionTimer = Timer.periodic(Duration(seconds: 1), (timer) {
        if (mounted && _isInitialized && _isConnected) {
          setState(() {
            _coinsLeft -= _coinsPerSecond;
            if (_coinsLeft < 0) _coinsLeft = 0;

            if (_coinsLeft > 0) {
              _estimatedMinutesLeft = (_coinsLeft / _coinsPerMinute).floor();
            } else {
              _estimatedMinutesLeft = 0;
            }
          });

          if (_coinsLeft <= LOW_COINS_THRESHOLD && !_lowCoinsWarningShown) {
            _lowCoinsWarningShown = true;
            _showLowCoinsWarning();
          }

          if (_estimatedMinutesLeft < 1 && _coinsLeft > 0 && !_lessMinuteWarningShown) {
            _lessMinuteWarningShown = true;
            _showLessMinuteWarning();
          }

          if (_coinsLeft <= 0) {
            debugPrint('❌ Coins depleted - ending call');
            timer.cancel();
            _endCall(showRating: true);
          }
        }
      });
    }
  }

  void _stopCoinDeduction() {
    debugPrint('💰 Stopping coin deduction');
    _coinDeductionTimer?.cancel();
    _coinDeductionTimer = null;
  }

  Future<void> _callCoinUpdateApi() async {
    if (widget.appointmentId == null) return;

    try {
      final userViewModel = Provider.of<UserViewModel>(context, listen: false);
      final token = userViewModel.userModel?.data.token;

      if (token == null || token.isEmpty) {
        debugPrint('❌ Coin update API: No token available');
        return;
      }

      debugPrint('🔄 Calling coin update API for appointment: ${widget.appointmentId}');

      final response = await http.post(
        Uri.parse(ApiEndPoints.COIN_UPDATE),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'appointment_id': widget.appointmentId}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        debugPrint('✅ Coin update API success: ${data.toString()}');

        // Refresh user data to get updated coin balance
        await Provider.of<UserViewModel>(context, listen: false).fetchUserData();

        // Update local coins display
        if (mounted && userViewModel.userModel != null) {
          final updatedCoins = userViewModel.userModel!.data.coins?.toDouble() ?? _coinsLeft;
          if (updatedCoins != _coinsLeft) {
            setState(() {
              _coinsLeft = updatedCoins;
              _estimatedMinutesLeft = (_coinsLeft / _coinsPerMinute).floor();
            });
            debugPrint('💰 Coins updated in UI: $_coinsLeft');
          }
        }
      } else {
        debugPrint('❌ Coin update API failed: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      debugPrint('❌ Error calling coin update API: $e');
    }
  }

  void _startCoinUpdateApiTimer() {
    if (widget.isCounselor || widget.appointmentId == null) return;

    debugPrint('🔄 Starting coin update API timer');
    _coinUpdateApiTimer = Timer.periodic(const Duration(minutes: 1), (timer) async {
      if (mounted && _isConnected) {
        await _callCoinUpdateApi();
      }
    });
  }

  void _stopCoinUpdateApiTimer() {
    debugPrint('🔄 Stopping coin update API timer');
    _coinUpdateApiTimer?.cancel();
    _coinUpdateApiTimer = null;
  }

  void _showLowCoinsWarning() {
    Get.snackbar(
      '⚠️ Low Coins Warning'.tr,
      'You have less than $LOW_COINS_THRESHOLD coins remaining.'.tr,
      backgroundColor: Colors.orange,
      colorText: Colors.white,
      snackPosition: SnackPosition.TOP,
      duration: Duration(seconds: 5),
    );
  }

  void _showLessMinuteWarning() {
    Get.snackbar(
      '⚠️ Call Ending Soon'.tr,
      'Less than 1 minute remaining. Please recharge to continue.'.tr,
      backgroundColor: Colors.red,
      colorText: Colors.white,
      snackPosition: SnackPosition.TOP,
      duration: Duration(seconds: 10),
      isDismissible: false,
    );
  }

  void _showInsufficientCoinsDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20.r)),
        title: Row(
          children: [
            Icon(Icons.warning, color: Colors.orange, size: 28.w),
            SizedBox(width: 10.w),
            Expanded(
              child: CustomText(
                text: "Insufficient Coins".tr,
                fontSize: FontConstants.font_18,
                weight: FontWeightConstants.bold,
                color: Colors.black87,
              ),
            ),
          ],
        ),
        content: CustomText(
          text: "You don't have enough coins for this call. Please recharge.".tr,
          fontSize: FontConstants.font_14,
          weight: FontWeightConstants.regular,
          color: Colors.black54,
        ),
        actions: [
          TextButton(
            onPressed: () {
              Get.back();
              Get.back();
            },
            child: CustomText(
              text: "Go Back".tr,
              fontSize: FontConstants.font_14,
              weight: FontWeightConstants.medium,
              color: Colors.grey[600]!,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _handleSessionEnded() async {
    if (!widget.isCounselor && widget.appointmentId != null && widget.counselorId != null) {
      final appointmentId = widget.appointmentId!;
      final counselorId = widget.counselorId!;
      final counselorName = widget.counselorName;
      final counselorImage = widget.counselorImage;
      final callDuration = _callDuration;

      _completeAppointmentApi();
      _disposeResources();

      if (mounted) {
        Navigator.of(context).pop();
      }

      await Future.delayed(Duration(milliseconds: 600));

      await Get.dialog(
        CallRatingDialog(
          appointmentId: appointmentId,
          counselorId: counselorId,
          counselorName: counselorName,
          counselorImage: counselorImage,
          callDuration: callDuration,
        ),
        barrierDismissible: false,
      );
      return;
    }

    _disposeResources();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Error'.tr),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () {
              Get.back();
              _endCall();
            },
            child: Text('OK'.tr),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleMicrophone() async {
    await _webrtcService?.toggleMicrophone();
    setState(() {
      _isMicrophoneEnabled = !_isMicrophoneEnabled;
    });
  }

  void _toggleSpeaker() {
    setState(() {
      _isSpeakerEnabled = !_isSpeakerEnabled;
    });
    // WebRTC speaker toggle logic depends on implementation
  }

  Future<void> _endCall({bool showRating = true}) async {
    await CallStateManager.clearCallState();

    if (!widget.isCounselor) {
      _sendEndTimeApi();
      await _completeAppointmentApi();

      if (showRating && widget.appointmentId != null && widget.counselorId != null) {
        _disposeResources();

        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => CallRatingDialog(
            appointmentId: widget.appointmentId!,
            counselorId: widget.counselorId!,
            counselorName: widget.counselorName,
            counselorImage: widget.counselorImage,
            callDuration: _callDuration,
          ),
        );

        if (mounted) {
          Navigator.of(context).pop();
        }
        return;
      }
    }

    _disposeResources();
    Get.back();
  }

  void _disposeResources() {
    _callTimer?.cancel();
    _coinDeductionTimer?.cancel();
    _coinUpdateApiTimer?.cancel();
    _pulseController.dispose();
    _webrtcService?.dispose();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposeResources();
    super.dispose();
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // Background gradient
            Container(
              width: double.infinity,
              height: double.infinity,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    primaryColor.withOpacity(0.8),
                    primaryColor.withOpacity(0.6),
                    Colors.black,
                  ],
                ),
              ),
            ),

            // Main content
            _buildMainContent(),

            if (_isInitialized)
              Positioned(
                bottom: 120.h,
                child: Container(
                  width: Get.width,
                  padding: EdgeInsets.symmetric(
                    horizontal: 20.w,
                    vertical: 10.h,
                  ),
                  child: Row(
                    children: [
                      _buildCoinsWidget(),
                      const Spacer(),
                      widget.isTroat
                          ? _buildTarotButton()
                          : const SizedBox.shrink(),
                    ],
                  ),
                ),
              ),

            // Bottom controls
            _buildBottomControls(),

            // Loading overlay
            if (_isLoading) _buildLoadingOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _buildCoinsWidget() {
    return CoinBalanceWidget(
      coinsLeft: _coinsLeft,
      estimatedMinutesLeft: _estimatedMinutesLeft,
      lowCoinsThreshold: LOW_COINS_THRESHOLD,
      isCounselor: widget.isCounselor,
    );
  }

  Widget _buildTarotButton() {
    return GestureDetector(
      onTap: () {
        _openTarotWebBrowser(context, widget.isCounselor);
      },
      child: Container(
        padding: EdgeInsets.all(10.w),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.2),
          shape: BoxShape.circle,
        ),
        child: Icon(Icons.auto_awesome, color: Colors.white, size: 24.w),
      ),
    );
  }

  void _openTarotWebBrowser(BuildContext context, bool isCounselor) {
    late final WebViewController controller;

    final settingsProvider = context.read<SettingProvider>();
    if (settingsProvider.settings == null) return;
    
    final settings = settingsProvider.settings!;
    final String tarotUrl1 = isCounselor ? settings.tarotCounselorsUrl : settings.tarotQuerentsUrl;

    final String tarotUrl = tarotUrl1.isNotEmpty
        ? tarotUrl1
        : isCounselor
            ? 'http://47.236.118.189:443'
            : 'http://47.236.118.189:443/querents';

    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..enableZoom(true)
      ..loadRequest(Uri.parse(tarotUrl));

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      isDismissible: true,
      enableDrag: false,
      builder: (context) => Container(
        height: Get.height * 0.95,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(20.r),
            topRight: Radius.circular(20.r),
          ),
        ),
        child: Column(
          children: [
            Container(
              padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(20.r),
                  topRight: Radius.circular(20.r),
                ),
                border: Border(bottom: BorderSide(color: Colors.grey[200]!, width: 1)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  CustomText(
                    text: 'Tarot'.tr,
                    fontSize: FontConstants.font_18,
                    weight: FontWeightConstants.bold,
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: WebViewWidget(controller: controller),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMainContent() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Counselor avatar with pulse animation
          AnimatedBuilder(
            animation: _pulseAnimation,
            builder: (context, child) {
              return Transform.scale(
                scale: _pulseAnimation.value,
                child: Container(
                  width: 200.w,
                  height: 200.w,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withOpacity(0.3),
                      width: 4,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.white.withOpacity(0.2),
                        blurRadius: 20,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  child: ClipOval(
                    child: widget.counselorImage != null && widget.counselorImage!.isNotEmpty
                        ? Image.network(
                            widget.counselorImage!,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) =>
                                Icon(Icons.person, size: 100.w, color: Colors.white),
                          )
                        : Icon(Icons.person, size: 100.w, color: Colors.white),
                  ),
                ),
              );
            },
          ),

          UIHelper.verticalSpaceMd,

          // Counselor name
          CustomText(
            text: widget.counselorName,
            fontSize: FontConstants.font_28,
            weight: FontWeightConstants.bold,
            color: Colors.white,
          ),

          UIHelper.verticalSpaceMd,

          // Call status
          CustomText(
            text: _isConnected ? "Connected".tr : "Connecting...".tr,
            fontSize: FontConstants.font_16,
            weight: FontWeightConstants.medium,
            color: Colors.white70,
          ),

          UIHelper.verticalSpaceMd,

          // Call duration
          if (_isConnected)
            CustomText(
              text: _formatDuration(_callDuration),
              fontSize: FontConstants.font_18,
              weight: FontWeightConstants.bold,
              color: Colors.white,
            ),
        ],
      ),
    );
  }

  Widget _buildBottomControls() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 40.w, vertical: 40.h),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            // Mute button
            _buildControlButton(
              icon: _isMicrophoneEnabled ? Icons.mic : Icons.mic_off,
              isActive: _isMicrophoneEnabled,
              onTap: _toggleMicrophone,
            ),

            // Speaker button
            _buildControlButton(
              icon: _isSpeakerEnabled ? Icons.volume_up : Icons.volume_off,
              isActive: _isSpeakerEnabled,
              onTap: _toggleSpeaker,
            ),

            // End call button
            _buildControlButton(
              icon: Icons.call_end,
              isActive: false,
              backgroundColor: Colors.red,
              onTap: _showEndCallConfirmation,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required bool isActive,
    required VoidCallback onTap,
    Color? backgroundColor,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 70.w,
        height: 70.w,
        decoration: BoxDecoration(
          color: backgroundColor ?? (isActive ? Colors.white : Colors.white.withOpacity(0.3)),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 10,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Icon(
          icon,
          color: backgroundColor != null ? Colors.white : (isActive ? Colors.black : Colors.white),
          size: 32.w,
        ),
      ),
    );
  }

  void _showEndCallConfirmation() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20.r)),
        title: CustomText(
          text: "End Call?".tr,
          fontSize: FontConstants.font_18,
          weight: FontWeightConstants.bold,
          color: Colors.black87,
        ),
        content: CustomText(
          text: "Are you sure you want to end this call?".tr,
          fontSize: FontConstants.font_14,
          weight: FontWeightConstants.regular,
          color: Colors.black54,
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: CustomText(
              text: "Cancel".tr,
              fontSize: FontConstants.font_14,
              weight: FontWeightConstants.medium,
              color: Colors.grey[600]!,
            ),
          ),
          TextButton(
            onPressed: () {
              Get.back();
              _endCall();
            },
            child: CustomText(
              text: "End Call".tr,
              fontSize: FontConstants.font_14,
              weight: FontWeightConstants.bold,
              color: Colors.red,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingOverlay() {
    return Container(
      color: Colors.black.withOpacity(0.8),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
            ),
            UIHelper.verticalSpaceMd,
            CustomText(
              text: "Connecting to call...".tr,
              fontSize: FontConstants.font_16,
              weight: FontWeightConstants.medium,
              color: Colors.white,
            ),
          ],
        ),
      ),
    );
  }

  void _saveCurrentCallState() {
    if (!_isConnected) return;

    CallStateManager.saveCallState(
      callType: 'voice',
      channelName: widget.channelName,
      counselorName: widget.counselorName,
      userId: widget.userId,
      counselorRate: widget.counselorRate,
      appointmentId: widget.appointmentId,
      counselorId: widget.counselorId,
      counselorImage: widget.counselorImage,
      isCounselor: widget.isCounselor,
      callDurationSeconds: _callDuration.inSeconds,
      coinsLeft: _coinsLeft,
      isTroat: widget.isTroat,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    switch (state) {
      case AppLifecycleState.paused:
        _saveCurrentCallState();
        break;
      case AppLifecycleState.resumed:
        CallStateManager.clearCallState();
        break;
      case AppLifecycleState.detached:
        _saveCurrentCallState();
        break;
      default:
        break;
    }
  }
}
